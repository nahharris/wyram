use crate::ClientPacket;
use std::collections::VecDeque;
use std::io::{self, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

const EDIT_CAPACITY: usize = 128;

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
                pending: VecDeque::with_capacity(EDIT_CAPACITY + 1),
                edits: 0,
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
        match packet {
            ClientPacket::Input { .. } => {
                if let Some(index) = state
                    .pending
                    .iter()
                    .position(|p| matches!(p.packet, ClientPacket::Input { .. }))
                {
                    state.pending.remove(index);
                    state.stats.coalesced_inputs += 1;
                }
            }
            ClientPacket::Edit { .. } => {
                if state.edits == EDIT_CAPACITY {
                    return Err(SendError::Full);
                }
                state.edits += 1;
            }
        }
        state.pending.push_back(Pending {
            packet,
            queued_at: Instant::now(),
        });
        state.stats.queued = state.pending.len();
        drop(state);
        self.shared.ready.notify_one();
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.shared.state.lock().unwrap().stats
    }
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
                sneaking: false,
                crawling: false,
                climbing: false,
            },
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
