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
    pub inbound_decode_ms: f64,
    pub inbound_wire_bytes: usize,
    pub inbound_queue_max_ms: f64,
    pub worker_mesh_ms: f64,
    pub upload_cpu_ms: f64,
    pub blended_prepare_cpu_ms: f64,
    pub blended_write_bytes: usize,
    pub blended_collect_cpu_ms: f64,
    pub blended_sort_cpu_ms: f64,
    pub blended_write_cpu_ms: f64,
    pub blended_quads: usize,
    pub surface_acquire_ms: f64,
    pub render_encode_cpu_ms: f64,
    pub render_submit_cpu_ms: f64,
    pub opaque_draws: usize,
    pub opaque_vertices: usize,
    pub gpu_render_ms: Option<f64>,
    pub uploaded_meshes: usize,
    pub uploaded_bytes: usize,
    pub stale_meshes: usize,
    pub loaded_chunks: usize,
    pub dirty_chunks: usize,
    pub in_flight: usize,
    pub observer_position: [f32; 3],
    pub approved_flight: bool,
    pub benchmark_elapsed_ms: f64,
    pub benchmark_phase: &'static str,
    pub scenery_update_cpu_ms: f64,
    pub scenery_worker_mesh_ms: f64,
    pub scenery_upload_cpu_ms: f64,
    pub scenery_uploads: usize,
    pub scenery_upload_bytes: usize,
    pub scenery_stale_meshes: usize,
    pub scenery_degraded_meshes: usize,
    pub scenery_degraded_ready_tiles: usize,
    pub scenery_ready_tiles: usize,
    pub scenery_selected_tiles: usize,
    pub scenery_in_flight: usize,
    pub scenery_failed_tiles: usize,
    pub scenery_mesh_reserved_bytes: usize,
    pub scenery_opaque_draws: usize,
    pub scenery_opaque_vertices: usize,
    pub dropped_samples: u64,
    pub outbound_queued: usize,
    pub outbound_sent: u64,
    pub outbound_coalesced_poses: u64,
    pub outbound_coalesced_inputs: u64,
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

    #[test]
    fn frame_capture_attributes_blended_uploads_and_surface_wait() {
        let path = std::env::temp_dir().join(format!(
            "wyram-phases-{}-{:?}.jsonl",
            std::process::id(),
            std::thread::current().id()
        ));
        let mut capture = FrameTelemetry::open(&path).unwrap();
        capture.record(FrameSample {
            blended_prepare_cpu_ms: 2.5,
            blended_write_bytes: 4096,
            surface_acquire_ms: 7.0,
            render_encode_cpu_ms: 0.3,
            render_submit_cpu_ms: 0.4,
            opaque_draws: 12,
            opaque_vertices: 2048,
            ..FrameSample::default()
        });
        drop(capture);
        let text = std::fs::read_to_string(&path).unwrap();
        let sample: serde_json::Value = serde_json::from_str(text.trim()).unwrap();
        assert_eq!(sample["blended_prepare_cpu_ms"], 2.5);
        assert_eq!(sample["blended_write_bytes"], 4096);
        assert_eq!(sample["surface_acquire_ms"], 7.0);
        assert_eq!(sample["opaque_draws"], 12);
        assert_eq!(sample["opaque_vertices"], 2048);
        std::fs::remove_file(path).unwrap();
    }
}
