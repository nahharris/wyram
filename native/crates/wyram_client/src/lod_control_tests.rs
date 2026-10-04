use super::*;
use std::io::Write;
use std::sync::mpsc;
use std::time::Duration;

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

fn lod_config() -> lod_runtime::LodConfig {
    lod_runtime::LodConfig {
        protocol: 1,
        enabled: true,
        generation_workers: 2,
        meshing_workers: 1,
        parallelism: 22,
        worker_budget: 8,
        near_radius: 11,
        max_cell_size: 16,
        min_y: -192,
        max_y: 319,
    }
}

#[test]
fn teleport_preserves_old_epoch_ack_to_release_engine_admission() {
    let mut game = Game::new();
    let mut lod = lod_runtime::LodRuntime::new(lod_config(), Instant::now()).unwrap();
    lod.epoch = 9;
    game.lod = Some(lod);
    let key = wyram_core::lod::TileKey::new(2, [3, 0, 4]).unwrap();
    game.send_lod_acks(vec![(8, key, 12, false)]);
    game.prune_lod_control();
    assert_eq!(game.pending_lod_acks.len(), 1);
    assert_eq!(game.pending_lod_acks[0].0, 8);
}

#[test]
fn lod_ack_full_is_queued_and_retried_without_fatal_error_or_loss() {
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (outbound, worker) = outbound::Outbound::start(
        GateWriter {
            entered: entered_tx,
            release: release_rx,
            bytes: Vec::new(),
        },
        |_| panic!("unexpected connection failure"),
    );
    outbound
        .send(ClientPacket::Edit {
            x: -1,
            y: 0,
            z: 0,
            id: 1,
        })
        .unwrap();
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    for x in 0..256 {
        outbound
            .send(ClientPacket::LodAck {
                epoch: 9,
                tiles: vec![(2, x, 0, 0, x as u64 + 1, true)],
            })
            .unwrap();
    }

    let mut game = Game::new();
    let mut lod = lod_runtime::LodRuntime::new(lod_config(), Instant::now()).unwrap();
    lod.epoch = 9;
    game.lod = Some(lod);
    game.outbound = Some(outbound);
    game.send_lod_acks(vec![(
        9,
        wyram_core::lod::TileKey::new(2, [300, 0, 0]).unwrap(),
        301,
        true,
    )]);
    assert_eq!(game.outbound_error, None);
    assert_eq!(game.pending_lod_acks.len(), 1);

    release_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !game.pending_lod_acks.is_empty() {
        game.retry_lod_control();
        assert!(Instant::now() < deadline, "LOD ACK was not retried");
        std::thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(game.outbound_error, None);
    drop(game);

    let packets = decode(&worker.join().unwrap().unwrap().bytes);
    let ack_ids: std::collections::BTreeSet<_> = packets
        .iter()
        .filter(|packet| packet["type"] == "lod_ack")
        .flat_map(|packet| packet["tiles"].as_array().unwrap())
        .map(|tile| {
            (
                tile[0].as_u64().unwrap() as u8,
                tile[1].as_i64().unwrap() as i32,
                tile[2].as_i64().unwrap() as i32,
                tile[3].as_i64().unwrap() as i32,
                tile[4].as_u64().unwrap(),
                tile[5].as_bool().unwrap(),
            )
        })
        .collect();
    assert_eq!(ack_ids.len(), 257);
    assert!(ack_ids.contains(&(2, 0, 0, 0, 1, true)));
    assert!(ack_ids.contains(&(2, 255, 0, 0, 256, true)));
    assert!(ack_ids.contains(&(2, 300, 0, 0, 301, true)));
}
