use serde::Serialize;
use std::fs::File;
use std::io::{self, BufWriter, Write};
use std::path::Path;
use std::sync::mpsc::{self, SyncSender};
use std::thread::JoinHandle;

#[derive(Default, Serialize)]
pub struct FrameSample {
    pub build_profile: &'static str,
    pub opt_level: &'static str,
    pub frame_ms: f64,
    pub redraw_cpu_ms: f64,
    pub decode_ms: f64,
    pub worker_mesh_ms: f64,
    pub upload_cpu_ms: f64,
    pub uploaded_meshes: usize,
    pub uploaded_bytes: usize,
    pub stale_meshes: usize,
    pub loaded_chunks: usize,
    pub dirty_chunks: usize,
    pub in_flight: usize,
    pub dropped_samples: u64,
    pub outbound_queued: usize,
    pub outbound_sent: u64,
    pub outbound_coalesced_poses: u64,
    pub outbound_queue_max_ms: f64,
    pub outbound_write_max_ms: f64,
}

#[derive(Default)]
pub struct FrameTelemetry {
    sender: Option<SyncSender<FrameSample>>,
    writer: Option<JoinHandle<()>>,
    dropped: u64,
}

impl FrameTelemetry {
    pub fn from_env() -> Self {
        match std::env::var_os("WYRAM_CLIENT_METRICS") {
            Some(path) => Self::open(Path::new(&path)).unwrap_or_else(|error| {
                eprintln!("frame capture unavailable: {error}");
                Self::default()
            }),
            None => Self::default(),
        }
    }

    fn open(path: &Path) -> io::Result<Self> {
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)?;
        }
        // A previous capture must not be silently overwritten.
        let file = File::create_new(path)?;
        let (sender, receiver) = mpsc::sync_channel::<FrameSample>(1024);
        let writer = std::thread::spawn(move || {
            let mut output = BufWriter::new(file);
            for sample in receiver {
                if let Err(error) = serde_json::to_writer(&mut output, &sample)
                    .map_err(io::Error::other)
                    .and_then(|()| output.write_all(b"\n"))
                {
                    eprintln!("frame capture failed: {error}");
                    break;
                }
            }
            if let Err(error) = output.flush() {
                eprintln!("frame capture flush failed: {error}");
            }
        });
        Ok(Self {
            sender: Some(sender),
            writer: Some(writer),
            dropped: 0,
        })
    }

    pub fn record(&mut self, mut sample: FrameSample) {
        if let Some(sender) = &self.sender {
            sample.dropped_samples = self.dropped;
            sample.build_profile = env!("WYRAM_NATIVE_PROFILE");
            sample.opt_level = env!("WYRAM_OPT_LEVEL");
            if sender.try_send(sample).is_err() {
                self.dropped += 1;
            }
        }
    }
}

impl Drop for FrameTelemetry {
    fn drop(&mut self) {
        self.sender.take();
        if let Some(writer) = self.writer.take() {
            let _ = writer.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saturated_capture_drops_samples_instead_of_blocking() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let mut capture = FrameTelemetry {
            sender: Some(sender),
            writer: None,
            dropped: 0,
        };
        capture.record(FrameSample::default());
        capture.record(FrameSample::default());
        assert_eq!(capture.dropped, 1);
        receiver.recv().unwrap();
        capture.record(FrameSample::default());
        assert_eq!(receiver.recv().unwrap().dropped_samples, 1);
    }

    #[test]
    fn shutdown_flushes_valid_json_lines() {
        let path = std::env::temp_dir().join(format!(
            "wyram-frames-{}-{:?}.jsonl",
            std::process::id(),
            std::thread::current().id()
        ));
        let mut capture = FrameTelemetry::open(&path).unwrap();
        capture.record(FrameSample {
            frame_ms: 12.5,
            loaded_chunks: 75,
            ..FrameSample::default()
        });
        drop(capture);
        let text = std::fs::read_to_string(&path).unwrap();
        let sample: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(sample["frame_ms"], 12.5);
        assert_eq!(sample["loaded_chunks"], 75);
        assert!(
            sample["build_profile"]
                .as_str()
                .is_some_and(|profile| !profile.is_empty())
        );
        std::fs::remove_file(path).unwrap();
    }
}
