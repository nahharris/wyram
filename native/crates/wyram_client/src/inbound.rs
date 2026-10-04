use crate::{
    ReceivedPacket, ServerPacket, decode_packet, outbound::ScenerySender, scenery::view::Reception,
};
use std::io::{self, Read};
use std::sync::mpsc::SyncSender;
use std::time::Instant;

pub fn read(
    input: &mut impl Read,
    sender: SyncSender<ReceivedPacket>,
    credits: &ScenerySender,
    mut ready: impl FnMut() -> bool,
) -> io::Result<()> {
    let mut reception = Reception::default();
    loop {
        let mut prefix = [0u8; 4];
        input.read_exact(&mut prefix)?;
        let length = u32::from_be_bytes(prefix) as usize;
        if length > 4 * 1024 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "packet too large",
            ));
        }
        let mut bytes = vec![0u8; length];
        input.read_exact(&mut bytes)?;
        let start = Instant::now();
        if let Some(packet) = decode_packet(&bytes) {
            let credit = match &packet {
                ServerPacket::SceneryPlan(plan) => {
                    reception.replace(plan);
                    None
                }
                ServerPacket::SceneryTiles(batch) if reception.accept(batch) => {
                    Some((batch.epoch, batch.delivery))
                }
                _ => None,
            };
            let packet = ReceivedPacket {
                packet,
                decode_cpu_ms: start.elapsed().as_secs_f64() * 1000.0,
                wire_bytes: length,
                queued_at: Instant::now(),
            };
            sender.send(packet).map_err(|_| io::ErrorKind::BrokenPipe)?;
            if !ready() {
                return Err(io::ErrorKind::BrokenPipe.into());
            }
            // Credit describes validated bounded queue admission, not UI work.
            // A full queue blocks only this reader; the renderer never waits.
            if let Some((epoch, delivery)) = credit {
                credits
                    .send(epoch, delivery)
                    .map_err(|_| io::ErrorKind::BrokenPipe)?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ServerPacket, outbound::Outbound, scenery::view::View};
    use std::io::{Cursor, Write};
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::time::Duration;
    use wyram_core::scenery::{LodTile, TileKey};

    const WAIT: Duration = Duration::from_secs(5);

    fn framed(payload: &[u8]) -> Vec<u8> {
        let mut bytes = (payload.len() as u32).to_be_bytes().to_vec();
        bytes.extend(payload);
        bytes
    }

    fn plan(epoch: u64, content: u64, x: i32) -> Vec<u8> {
        let mut bytes = b"WSP1".to_vec();
        for value in [epoch, content, 0] {
            bytes.extend(value.to_be_bytes());
        }
        bytes.extend(1024u16.to_be_bytes());
        for _ in 0..2 {
            bytes.extend(67_108_864u32.to_be_bytes());
        }
        for value in [1u16, 1, 0] {
            bytes.extend(value.to_be_bytes());
        }
        for value in [x, 0, 0] {
            bytes.extend(value.to_be_bytes());
        }
        bytes.extend([1, 0]);
        framed(&bytes)
    }

    fn batch(epoch: u64, delivery: u64, x: i32) -> Vec<u8> {
        let tile = LodTile::uniform(TileKey::new([x, 0, 0], 1).unwrap(), 42).encode();
        let mut bytes = b"WST1".to_vec();
        bytes.extend(epoch.to_be_bytes());
        bytes.extend(delivery.to_be_bytes());
        bytes.extend(1u16.to_be_bytes());
        bytes.extend((tile.len() as u32).to_be_bytes());
        bytes.extend(tile);
        framed(&bytes)
    }

    struct ObservedOutput {
        packets: Sender<serde_json::Value>,
        bytes: Vec<u8>,
    }
    impl Write for ObservedOutput {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.bytes.extend(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            let length = u32::from_be_bytes(self.bytes[..4].try_into().unwrap()) as usize;
            assert_eq!(self.bytes.len(), length + 4);
            self.packets
                .send(serde_json::from_slice(&self.bytes[4..]).unwrap())
                .unwrap();
            self.bytes.clear();
            Ok(())
        }
    }
    fn output() -> (
        Outbound,
        std::thread::JoinHandle<io::Result<ObservedOutput>>,
        Receiver<serde_json::Value>,
    ) {
        let (tx, rx) = mpsc::channel();
        let (outbound, worker) = Outbound::start(
            ObservedOutput {
                packets: tx,
                bytes: Vec::new(),
            },
            |_| panic!("write failed"),
        );
        (outbound, worker, rx)
    }
    fn credit(rx: &Receiver<serde_json::Value>, epoch: u64, delivery: u64) {
        let packet = rx
            .recv_timeout(WAIT)
            .expect("queue admission releases server credit without UI work");
        assert_eq!(packet["type"], "scenery_ready");
        assert_eq!(packet["epoch"], epoch);
        assert_eq!(packet["delivery"], delivery);
    }

    #[test]
    fn credits_follow_bounded_queue_admission_before_ui_acceptance() {
        let (outbound, writer, credits) = output();
        let handle = outbound.scenery_sender();
        let (tx, rx) = mpsc::sync_channel(1);
        let (notice_tx, notices) = mpsc::channel();
        let bytes = [plan(3, 7, 0), batch(3, 1, 0), batch(3, 2, 0)].concat();
        let reader = std::thread::spawn(move || {
            read(&mut Cursor::new(bytes), tx, &handle, || {
                notice_tx.send(()).is_ok()
            })
        });
        notices.recv_timeout(WAIT).unwrap();
        assert!(
            credits.try_recv().is_err(),
            "full queue cannot grant credit"
        );
        let ServerPacket::SceneryPlan(plan) = rx.recv_timeout(WAIT).unwrap().packet else {
            panic!("plan");
        };
        credit(&credits, 3, 1);
        notices.recv_timeout(WAIT).unwrap();
        assert!(
            credits.recv_timeout(Duration::from_millis(30)).is_err(),
            "next batch remains blocked"
        );
        let first = rx.recv_timeout(WAIT).unwrap();
        credit(&credits, 3, 2);
        let second = rx.recv_timeout(WAIT).unwrap();
        assert_eq!(
            reader.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
        let mut view = View::default();
        assert!(view.replace(plan));
        for packet in [first, second] {
            let ServerPacket::SceneryTiles(batch) = packet.packet else {
                panic!("batch");
            };
            assert!(view.accept(batch), "reader and UI validation agree");
        }
        assert_eq!(view.tiles.len(), 1);
        drop(outbound);
        writer.join().unwrap().unwrap();
    }

    struct StreamInput {
        packets: Receiver<Vec<u8>>,
        current: Cursor<Vec<u8>>,
    }
    impl Read for StreamInput {
        fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
            loop {
                let count = self.current.read(bytes)?;
                if count != 0 {
                    return Ok(count);
                }
                let Ok(packet) = self.packets.recv() else {
                    return Ok(0);
                };
                self.current = Cursor::new(packet);
            }
        }
    }

    #[test]
    fn only_current_valid_deliveries_release_credit_across_view_and_content_changes() {
        let (outbound, writer, credits) = output();
        let handle = outbound.scenery_sender();
        let (tx, rx) = mpsc::sync_channel(32);
        let (input_tx, input_rx) = mpsc::channel();
        let (notice_tx, notices) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            read(
                &mut StreamInput {
                    packets: input_rx,
                    current: Cursor::new(Vec::new()),
                },
                tx,
                &handle,
                || notice_tx.send(()).is_ok(),
            )
        });
        let cases = [
            (batch(3, 1, 0), None),
            (plan(3, 7, 0), None),
            (batch(3, 1, 99), None),
            (batch(3, 2, 0), Some((3, 2))),
            (batch(3, 2, 0), None),
            (batch(3, 1, 0), None),
            (plan(2, 8, 99), None),
            (batch(2, 3, 99), None),
            (plan(4, 9, 1), None),
            (batch(3, 4, 0), None),
            (batch(4, 7, 1), Some((4, 7))),
        ];
        let mut view = View::default();
        for (bytes, expected) in cases {
            input_tx.send(bytes).unwrap();
            notices.recv_timeout(WAIT).unwrap();
            let packet = rx.recv_timeout(WAIT).unwrap().packet;
            let accepted = match packet {
                ServerPacket::SceneryPlan(plan) => {
                    view.replace(plan);
                    false
                }
                ServerPacket::SceneryTiles(batch) => view.accept(batch),
                _ => panic!("scenery"),
            };
            assert_eq!(accepted, expected.is_some());
            if let Some((epoch, delivery)) = expected {
                credit(&credits, epoch, delivery);
            } else {
                assert!(credits.recv_timeout(Duration::from_millis(20)).is_err());
            }
        }
        drop(input_tx);
        assert!(reader.join().unwrap().is_err());
        assert_eq!(view.plan.as_ref().unwrap().content, 9);
        assert_eq!(view.tiles.len(), 1);
        drop(outbound);
        writer.join().unwrap().unwrap();
    }

    #[test]
    fn receiver_exit_while_a_batch_waits_cannot_release_credit() {
        let (outbound, writer, credits) = output();
        let handle = outbound.scenery_sender();
        let (tx, rx) = mpsc::sync_channel(1);
        let (notice_tx, notices) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            read(
                &mut Cursor::new([plan(3, 7, 0), batch(3, 1, 0)].concat()),
                tx,
                &handle,
                || notice_tx.send(()).is_ok(),
            )
        });
        notices.recv_timeout(WAIT).unwrap();
        // The plan occupies the only slot; the following tile cannot be admitted.
        drop(rx);
        assert_eq!(
            reader.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::BrokenPipe
        );
        assert!(credits.try_recv().is_err());
        drop(outbound);
        writer.join().unwrap().unwrap();
    }

    #[test]
    fn lost_event_loop_or_closed_writer_ends_admission_without_credit() {
        let (outbound, writer, credits) = output();
        let (tx, _rx) = mpsc::sync_channel(2);
        let mut notices = 0;
        assert_eq!(
            read(
                &mut Cursor::new([plan(3, 7, 0), batch(3, 1, 0)].concat()),
                tx,
                &outbound.scenery_sender(),
                || {
                    notices += 1;
                    notices == 1
                }
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::BrokenPipe
        );
        assert!(credits.try_recv().is_err());
        let handle = outbound.scenery_sender();
        drop(outbound);
        writer.join().unwrap().unwrap();
        let (tx, _rx) = mpsc::sync_channel(2);
        assert_eq!(
            read(
                &mut Cursor::new([plan(3, 7, 0), batch(3, 1, 0)].concat()),
                tx,
                &handle,
                || true
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::BrokenPipe
        );
        assert!(credits.try_recv().is_err());
    }

    #[test]
    fn closed_queue_and_invalid_frames_cannot_grant_credit() {
        let (outbound, writer, credits) = output();
        for bytes in [
            (4_194_305u32).to_be_bytes().to_vec(),
            vec![0, 0],
            framed(b"WST1"),
            plan(3, 7, 0)[..10].to_vec(),
        ] {
            let (tx, rx) = mpsc::sync_channel(1);
            assert!(
                read(
                    &mut Cursor::new(bytes),
                    tx,
                    &outbound.scenery_sender(),
                    || panic!("invalid packet admitted")
                )
                .is_err()
            );
            assert!(rx.try_recv().is_err());
            assert!(credits.try_recv().is_err());
        }
        let (tx, rx) = mpsc::sync_channel(1);
        drop(rx);
        assert_eq!(
            read(
                &mut Cursor::new([plan(3, 7, 0), batch(3, 1, 0)].concat()),
                tx,
                &outbound.scenery_sender(),
                || true
            )
            .unwrap_err()
            .kind(),
            io::ErrorKind::BrokenPipe
        );
        assert!(credits.try_recv().is_err());
        drop(outbound);
        writer.join().unwrap().unwrap();
    }
}
