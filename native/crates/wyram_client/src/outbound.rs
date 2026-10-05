use crate::ClientPacket;
use std::collections::{HashSet, VecDeque};
use std::io::{self, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

const EDIT_CAPACITY: usize = 128;
const LOD_CONTROL_PACKETS: usize = 16;
const LOD_CONTROL_ITEMS: usize = 16;

#[derive(Debug, PartialEq, Eq)]
pub enum SendError {
    Full,
    Closed,
}

#[derive(Clone, Copy, Default)]
pub struct Snapshot {
    pub queued: usize,
    pub coalesced_inputs: u64,
    pub sent: u64,
    pub queue_max_ms: f64,
    pub write_max_ms: f64,
}

struct Pending {
    packet: ClientPacket,
    queued_at: Instant,
}

struct State {
    pending: VecDeque<Pending>,
    edits: usize,
    capabilities_announced: bool,
    closing: bool,
    failed: bool,
    stats: Snapshot,
}

struct Shared {
    state: Mutex<State>,
    ready: Condvar,
}

pub struct Outbound {
    shared: Arc<Shared>,
}

impl Outbound {
    pub fn start<W, F>(mut output: W, on_error: F) -> (Self, JoinHandle<io::Result<W>>)
    where
        W: Write + Send + 'static,
        F: FnOnce(io::Error) + Send + 'static,
    {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                pending: VecDeque::with_capacity(EDIT_CAPACITY + 2),
                edits: 0,
                capabilities_announced: false,
                closing: false,
                failed: false,
                stats: Snapshot::default(),
            }),
            ready: Condvar::new(),
        });
        let worker_shared = shared.clone();
        let worker = std::thread::spawn(move || {
            loop {
                let pending = {
                    let mut state = worker_shared.state.lock().unwrap();
                    while state.pending.is_empty() && !state.closing {
                        state = worker_shared.ready.wait(state).unwrap();
                    }
                    let Some(pending) = state.pending.pop_front() else {
                        break;
                    };
                    if matches!(pending.packet, ClientPacket::Edit { .. }) {
                        state.edits -= 1;
                    }
                    state.stats.queued = state.pending.len();
                    state.stats.queue_max_ms = state
                        .stats
                        .queue_max_ms
                        .max(pending.queued_at.elapsed().as_secs_f64() * 1000.0);
                    pending
                };
                // No queue lock is held while serializing, writing or flushing.
                let start = Instant::now();
                if let Err(error) = write_packet(&mut output, &pending.packet) {
                    {
                        let mut state = worker_shared.state.lock().unwrap();
                        state.failed = true;
                        state.pending.clear();
                        state.edits = 0;
                        state.stats.queued = 0;
                    }
                    let returned = io::Error::new(error.kind(), error.to_string());
                    on_error(error);
                    return Err(returned);
                }
                let mut state = worker_shared.state.lock().unwrap();
                state.stats.sent += 1;
                state.stats.write_max_ms = state
                    .stats
                    .write_max_ms
                    .max(start.elapsed().as_secs_f64() * 1000.0);
            }
            Ok(output)
        });
        (Self { shared }, worker)
    }

    pub fn send(&self, packet: ClientPacket) -> Result<(), SendError> {
        let mut state = self.shared.state.lock().unwrap();
        if state.failed || state.closing {
            return Err(SendError::Closed);
        }
        let packet = match packet {
            packet @ ClientPacket::Capabilities { .. } => {
                if state.capabilities_announced {
                    return Ok(());
                }
                state.capabilities_announced = true;
                Some(packet)
            }
            packet @ ClientPacket::Input { .. } => {
                if let Some(index) = state
                    .pending
                    .iter()
                    .position(|p| matches!(p.packet, ClientPacket::Input { .. }))
                {
                    state.pending.remove(index);
                    state.stats.coalesced_inputs += 1;
                }
                Some(packet)
            }
            packet @ ClientPacket::Edit { .. } => {
                if state.edits == EDIT_CAPACITY {
                    return Err(SendError::Full);
                }
                state.edits += 1;
                Some(packet)
            }
            ClientPacket::LodAck { epoch, tiles } => {
                merge_lod_acks(&mut state.pending, epoch, tiles)?;
                None
            }
            ClientPacket::LodNeed { epoch, keys } => {
                merge_lod_needs(&mut state.pending, epoch, keys)?;
                None
            }
        };
        if let Some(packet) = packet {
            state.pending.push_back(Pending {
                packet,
                queued_at: Instant::now(),
            });
        }
        state.stats.queued = state.pending.len();
        drop(state);
        self.shared.ready.notify_one();
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.shared.state.lock().unwrap().stats
    }
}

fn merge_lod_acks(
    pending: &mut VecDeque<Pending>,
    epoch: u64,
    incoming: Vec<(u8, i32, i32, i32, u64, bool)>,
) -> Result<(), SendError> {
    let mut unique = HashSet::new();
    let mut items: Vec<_> = incoming
        .into_iter()
        .filter(|item| unique.insert(*item))
        .collect();
    let mut existing = HashSet::new();
    let mut reusable_slots = 0usize;
    let mut packet_count = 0usize;
    for queued in pending.iter() {
        if let ClientPacket::LodAck {
            epoch: queued_epoch,
            tiles,
        } = &queued.packet
        {
            packet_count += 1;
            if *queued_epoch == epoch {
                reusable_slots += LOD_CONTROL_ITEMS.saturating_sub(tiles.len());
                existing.extend(tiles.iter().copied());
            }
        }
    }
    items.retain(|item| !existing.contains(item));
    if items.is_empty() {
        return Ok(());
    }
    let additional = items
        .len()
        .saturating_sub(reusable_slots)
        .div_ceil(LOD_CONTROL_ITEMS);
    if packet_count.saturating_add(additional) > LOD_CONTROL_PACKETS {
        return Err(SendError::Full);
    }

    for queued in pending.iter_mut() {
        if let ClientPacket::LodAck {
            epoch: queued_epoch,
            tiles,
        } = &mut queued.packet
            && *queued_epoch == epoch
            && tiles.len() < LOD_CONTROL_ITEMS
        {
            let count = (LOD_CONTROL_ITEMS - tiles.len()).min(items.len());
            tiles.extend(items.drain(..count));
            if items.is_empty() {
                break;
            }
        }
    }
    for chunk in items.chunks(LOD_CONTROL_ITEMS) {
        pending.push_back(Pending {
            packet: ClientPacket::LodAck {
                epoch,
                tiles: chunk.to_vec(),
            },
            queued_at: Instant::now(),
        });
    }
    Ok(())
}

fn merge_lod_needs(
    pending: &mut VecDeque<Pending>,
    epoch: u64,
    incoming: Vec<(u8, i32, i32, i32)>,
) -> Result<(), SendError> {
    let mut unique = HashSet::new();
    let mut items: Vec<_> = incoming
        .into_iter()
        .filter(|item| unique.insert(*item))
        .collect();
    let mut existing = HashSet::new();
    let mut reusable_slots = 0usize;
    let mut packet_count = 0usize;
    for queued in pending.iter() {
        if let ClientPacket::LodNeed {
            epoch: queued_epoch,
            keys,
        } = &queued.packet
        {
            packet_count += 1;
            if *queued_epoch == epoch {
                reusable_slots += LOD_CONTROL_ITEMS.saturating_sub(keys.len());
                existing.extend(keys.iter().copied());
            }
        }
    }
    items.retain(|item| !existing.contains(item));
    if items.is_empty() {
        return Ok(());
    }
    let additional = items
        .len()
        .saturating_sub(reusable_slots)
        .div_ceil(LOD_CONTROL_ITEMS);
    if packet_count.saturating_add(additional) > LOD_CONTROL_PACKETS {
        return Err(SendError::Full);
    }

    for queued in pending.iter_mut() {
        if let ClientPacket::LodNeed {
            epoch: queued_epoch,
            keys,
        } = &mut queued.packet
            && *queued_epoch == epoch
            && keys.len() < LOD_CONTROL_ITEMS
        {
            let count = (LOD_CONTROL_ITEMS - keys.len()).min(items.len());
            keys.extend(items.drain(..count));
            if items.is_empty() {
                break;
            }
        }
    }
    for chunk in items.chunks(LOD_CONTROL_ITEMS) {
        pending.push_back(Pending {
            packet: ClientPacket::LodNeed {
                epoch,
                keys: chunk.to_vec(),
            },
            queued_at: Instant::now(),
        });
    }
    Ok(())
}

impl Drop for Outbound {
    fn drop(&mut self) {
        self.shared.state.lock().unwrap().closing = true;
        self.shared.ready.notify_one();
        // Do not join: an OS pipe write may be stuck indefinitely. Process exit
        // terminates the worker; shutdown does not promise delivery or engine ACK.
    }
}

fn write_packet(output: &mut impl Write, packet: &ClientPacket) -> io::Result<()> {
    let bytes = serde_json::to_vec(packet).map_err(io::Error::other)?;
    let length = u32::try_from(bytes.len()).map_err(io::Error::other)?;
    output.write_all(&length.to_be_bytes())?;
    output.write_all(&bytes)?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn edit(x: i32) -> ClientPacket {
        ClientPacket::Edit {
            x,
            y: 2,
            z: -3,
            id: 7,
        }
    }

    fn input(sequence: u64, running: bool) -> ClientPacket {
        ClientPacket::Input {
            sequence,
            epoch: 0,
            intent: crate::Intent {
                forward: 1.0,
                right: 0.0,
                yaw: 0.0,
                pitch: 0.0,
                running,
                jump: false,
                flight_request: 0,
                sneaking: false,
                crawling: false,
                climbing: false,
                rolling: false,
                cancel_actions: false,
            },
        }
    }

    fn lod_ack(epoch: u64, x: i32) -> ClientPacket {
        ClientPacket::LodAck {
            epoch,
            tiles: vec![(2, x, -3, 4, x as u64 + 1, true)],
        }
    }

    fn lod_need(epoch: u64, x: i32) -> ClientPacket {
        ClientPacket::LodNeed {
            epoch,
            keys: vec![(4, x, 5, -6)],
        }
    }

    struct GateWriter {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
        bytes: Vec<u8>,
    }

    impl Write for GateWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if self.bytes.is_empty() {
                self.entered.send(()).unwrap();
                self.release.recv().unwrap();
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn decode(mut bytes: &[u8]) -> Vec<serde_json::Value> {
        let mut packets = Vec::new();
        while !bytes.is_empty() {
            let length = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
            packets.push(serde_json::from_slice(&bytes[4..4 + length]).unwrap());
            bytes = &bytes[4 + length..];
        }
        packets
    }

    #[test]
    fn blocked_receiver_keeps_admission_bounded_and_edits_ordered() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(
            GateWriter {
                entered: entered_tx,
                release: release_rx,
                bytes: Vec::new(),
            },
            |_| panic!("unexpected connection failure"),
        );
        outbound.send(edit(-1)).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // If admission touches the pipe or the writer holds the queue lock,
        // this producer cannot finish until the gate is released.
        let producer = std::thread::spawn(move || {
            for x in 0..EDIT_CAPACITY as i32 {
                outbound.send(edit(x)).unwrap();
                outbound.send(input(x as u64, x % 2 == 0)).unwrap();
            }
            assert_eq!(outbound.send(edit(999)), Err(SendError::Full));
            assert_eq!(outbound.snapshot().queued, EDIT_CAPACITY + 1);
            assert_eq!(
                outbound.snapshot().coalesced_inputs,
                EDIT_CAPACITY as u64 - 1
            );
            outbound
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !producer.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(1));
        }
        let finished_without_receiver = producer.is_finished();
        release_tx.send(()).unwrap();
        let outbound = producer.join().unwrap();
        drop(outbound);
        let bytes = worker.join().unwrap().unwrap().bytes;
        assert!(finished_without_receiver, "producer waited for pipe I/O");
        let packets = decode(&bytes);
        assert_eq!(packets.len(), EDIT_CAPACITY + 2);
        for (index, packet) in packets[..EDIT_CAPACITY + 1].iter().enumerate() {
            assert_eq!(packet["type"], "edit");
            assert_eq!(packet["x"], index as i32 - 1);
            assert_eq!(packet["id"], 7);
        }
        assert_eq!(packets.last().unwrap()["type"], "input");
        assert_eq!(
            packets.last().unwrap()["sequence"],
            EDIT_CAPACITY as u64 - 1
        );
        assert_eq!(packets.last().unwrap()["running"], false);
    }

    #[test]
    fn repeated_capabilities_cannot_grow_a_blocked_outbound_queue() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(
            GateWriter {
                entered: entered_tx,
                release: release_rx,
                bytes: Vec::new(),
            },
            |_| panic!("unexpected connection failure"),
        );
        outbound.send(edit(-1)).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        for _ in 0..1000 {
            outbound
                .send(ClientPacket::Capabilities {
                    chunk_protocol: 1,
                    forget_protocol: 1,
                    lod_protocol: 1,
                    available_parallelism: Some(4),
                })
                .unwrap();
        }
        assert_eq!(outbound.snapshot().queued, 1);
        release_tx.send(()).unwrap();
        drop(outbound);
        let packets = decode(&worker.join().unwrap().unwrap().bytes);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[1]["type"], "capabilities");
        assert_eq!(packets[1]["chunk_protocol"], 1);
    }

    #[test]
    fn blocked_lod_control_coalesces_deduplicates_and_returns_full_without_loss() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(
            GateWriter {
                entered: entered_tx,
                release: release_rx,
                bytes: Vec::new(),
            },
            |_| panic!("unexpected connection failure"),
        );
        outbound.send(edit(-1)).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();

        for x in 0..256 {
            outbound.send(lod_ack(7, x)).unwrap();
            outbound.send(lod_need(7, x)).unwrap();
        }
        // Exact retries are harmless even when both bounded control queues are full.
        outbound.send(lod_ack(7, 0)).unwrap();
        outbound.send(lod_need(7, 0)).unwrap();
        assert_eq!(outbound.send(lod_ack(7, 256)), Err(SendError::Full));
        assert_eq!(outbound.send(lod_need(7, 256)), Err(SendError::Full));
        assert_eq!(outbound.snapshot().queued, 32);

        release_tx.send(()).unwrap();
        drop(outbound);
        let packets = decode(&worker.join().unwrap().unwrap().bytes);
        let mut acks = std::collections::BTreeSet::new();
        let mut needs = std::collections::BTreeSet::new();
        for packet in packets {
            match packet["type"].as_str().unwrap() {
                "lod_ack" => {
                    assert_eq!(packet["epoch"], 7);
                    let tiles = packet["tiles"].as_array().unwrap();
                    assert!(!tiles.is_empty() && tiles.len() <= 16);
                    for tile in tiles {
                        acks.insert((
                            tile[0].as_u64().unwrap() as u8,
                            tile[1].as_i64().unwrap() as i32,
                            tile[2].as_i64().unwrap() as i32,
                            tile[3].as_i64().unwrap() as i32,
                            tile[4].as_u64().unwrap(),
                            tile[5].as_bool().unwrap(),
                        ));
                    }
                }
                "lod_need" => {
                    assert_eq!(packet["epoch"], 7);
                    let keys = packet["keys"].as_array().unwrap();
                    assert!(!keys.is_empty() && keys.len() <= 16);
                    for key in keys {
                        needs.insert((
                            key[0].as_u64().unwrap() as u8,
                            key[1].as_i64().unwrap() as i32,
                            key[2].as_i64().unwrap() as i32,
                            key[3].as_i64().unwrap() as i32,
                        ));
                    }
                }
                "edit" => {}
                other => panic!("unexpected outbound packet {other}"),
            }
        }
        assert_eq!(acks.len(), 256);
        assert_eq!(needs.len(), 256);
        assert!(acks.contains(&(2, 0, -3, 4, 1, true)));
        assert!(acks.contains(&(2, 255, -3, 4, 256, true)));
        assert!(needs.contains(&(4, 0, 5, -6)));
        assert!(needs.contains(&(4, 255, 5, -6)));
    }

    #[test]
    fn flight_requests_survive_coalescing_with_a_released_space_key() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(
            GateWriter {
                entered: entered_tx,
                release: release_rx,
                bytes: Vec::new(),
            },
            |_| panic!("unexpected connection failure"),
        );
        outbound.send(edit(1)).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let mut pressed = input(1, false);
        if let ClientPacket::Input { intent, .. } = &mut pressed {
            intent.jump = true;
            intent.flight_request = 1;
        }
        outbound.send(pressed).unwrap();
        let mut released = input(2, false);
        if let ClientPacket::Input { intent, .. } = &mut released {
            intent.flight_request = 1;
        }
        outbound.send(released).unwrap();
        release_tx.send(()).unwrap();
        drop(outbound);
        let packets = decode(&worker.join().unwrap().unwrap().bytes);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[1]["sequence"], 2);
        assert_eq!(packets[1]["flight_request"], 1);
        assert_eq!(packets[1]["jump"], false);
    }

    struct ClosedWriter;
    impl Write for ClosedWriter {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "receiver closed"))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn closed_receiver_notifies_once_and_rejects_further_packets() {
        let (tx, rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(ClosedWriter, move |error| {
            tx.send(error.kind()).unwrap();
        });
        outbound.send(edit(1)).unwrap();
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(5)).unwrap(),
            io::ErrorKind::BrokenPipe
        );
        assert_eq!(outbound.send(edit(2)), Err(SendError::Closed));
        assert!(worker.join().unwrap().is_err());
        assert!(rx.try_recv().is_err());
    }

    #[cfg(windows)]
    #[test]
    fn windows_delayed_pipe_receiver_gets_every_admitted_edit() {
        use std::io::Read;
        use std::process::{Command, Stdio};
        let mut receiver = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command",
                "Start-Sleep -Milliseconds 200; [Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
            .spawn().unwrap();
        let input = receiver.stdin.take().unwrap();
        let mut output = receiver.stdout.take().unwrap();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            output.read_to_end(&mut bytes).unwrap();
            bytes
        });
        let (outbound, worker) = Outbound::start(input, |_| panic!("write failed"));
        let mut expected = Vec::new();
        for x in 0..EDIT_CAPACITY as i32 {
            outbound.send(edit(x)).unwrap();
            write_packet(&mut expected, &edit(x)).unwrap();
        }
        drop(outbound);
        drop(worker.join().unwrap().unwrap()); // Close stdin so CopyTo reaches EOF.
        assert!(receiver.wait().unwrap().success());
        assert_eq!(reader.join().unwrap(), expected);
    }

    #[cfg(windows)]
    #[test]
    fn windows_closed_anonymous_pipe_reports_broken_connection() {
        use std::process::{Command, Stdio};
        let mut receiver = Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", "exit 0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let input = receiver.stdin.take().unwrap();
        assert!(receiver.wait().unwrap().success());
        let (tx, rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(input, move |error| {
            tx.send(error.kind()).unwrap();
        });
        outbound.send(edit(1)).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(outbound.send(edit(2)), Err(SendError::Closed));
        assert!(worker.join().unwrap().is_err());
    }

    struct SlowWriter {
        bytes: Vec<u8>,
    }
    impl Write for SlowWriter {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            std::thread::sleep(Duration::from_millis(2));
            Ok(())
        }
    }

    #[test]
    #[ignore = "manual matched slow-receiver benchmark; no timing thresholds in CI"]
    fn benchmark_outbound_backpressure() {
        let path = std::env::var_os("WYRAM_OUTBOUND_BENCH_OUTPUT").expect("set benchmark output");
        let mut capture = std::fs::File::create_new(path).unwrap();
        for round in 0..6 {
            for asynchronous in if round % 2 == 0 {
                [false, true]
            } else {
                [true, false]
            } {
                let mut durations = Vec::new();
                let start = Instant::now();
                let bytes = if asynchronous {
                    let (outbound, worker) =
                        Outbound::start(SlowWriter { bytes: Vec::new() }, |_| {
                            panic!("write failed")
                        });
                    for x in 0..64 {
                        let send = Instant::now();
                        outbound.send(edit(x)).unwrap();
                        durations.push(send.elapsed().as_secs_f64() * 1000.0);
                    }
                    drop(outbound);
                    worker.join().unwrap().unwrap().bytes
                } else {
                    let mut writer = SlowWriter { bytes: Vec::new() };
                    for x in 0..64 {
                        let send = Instant::now();
                        write_packet(&mut writer, &edit(x)).unwrap();
                        durations.push(send.elapsed().as_secs_f64() * 1000.0);
                    }
                    writer.bytes
                };
                let elapsed = start.elapsed().as_secs_f64() * 1000.0;
                let packets = decode(&bytes);
                assert_eq!(packets.len(), 64);
                for (x, packet) in packets.iter().enumerate() {
                    assert_eq!(packet["x"], x as i32);
                }
                serde_json::to_writer(
                    &mut capture,
                    &serde_json::json!({
                        "round": round, "async": asynchronous,
                        "profile": env!("WYRAM_NATIVE_PROFILE"),
                        "send_ms": durations, "drained_ms": elapsed,
                        "bytes": bytes.len(), "packets": packets.len(),
                    }),
                )
                .unwrap();
                capture.write_all(b"\n").unwrap();
            }
        }
    }
}
