use std::sync::mpsc::{self, Receiver, SyncSender};

fn elapsed_ms(start: u64, end: u64, period: f32) -> Option<f64> {
    if !period.is_finite() || period <= 0.0 {
        return None;
    }
    Some(end.checked_sub(start)? as f64 * f64::from(period) / 1_000_000.0)
}

/// One outstanding readback. Rendering skips sampling until it is ready;
/// neither GPU completion nor buffer mapping is ever waited for on redraw.
pub struct GpuTimer {
    queries: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    readback: wgpu::Buffer,
    sender: SyncSender<Result<(), wgpu::BufferAsyncError>>,
    receiver: Receiver<Result<(), wgpu::BufferAsyncError>>,
    pending: bool,
    period: f32,
}

impl GpuTimer {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Self {
        let queries = device.create_query_set(&wgpu::QuerySetDescriptor {
            label: Some("World GPU timestamps"),
            ty: wgpu::QueryType::Timestamp,
            count: 2,
        });
        let buffer = |label, usage| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: 16,
                usage,
                mapped_at_creation: false,
            })
        };
        let (sender, receiver) = mpsc::sync_channel(1);
        Self {
            queries,
            resolve: buffer(
                "GPU timestamp resolve",
                wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
            ),
            readback: buffer(
                "GPU timestamp readback",
                wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            ),
            sender,
            receiver,
            pending: false,
            period: queue.get_timestamp_period(),
        }
    }

    pub fn collect(&mut self, device: &wgpu::Device) -> Option<f64> {
        let _ = device.poll(wgpu::PollType::Poll);
        let result = self.receiver.try_recv().ok()?;
        self.pending = false;
        let elapsed = if result.is_ok() {
            self.readback
                .slice(..)
                .get_mapped_range()
                .ok()
                .and_then(|bytes| {
                    elapsed_ms(
                        u64::from_ne_bytes(bytes[..8].try_into().unwrap()),
                        u64::from_ne_bytes(bytes[8..16].try_into().unwrap()),
                        self.period,
                    )
                })
        } else {
            None
        };
        self.readback.unmap();
        elapsed
    }

    pub fn writes(&self) -> Option<wgpu::RenderPassTimestampWrites<'_>> {
        (!self.pending).then_some(wgpu::RenderPassTimestampWrites {
            query_set: &self.queries,
            beginning_of_pass_write_index: Some(0),
            end_of_pass_write_index: Some(1),
        })
    }

    pub fn resolve(&self, encoder: &mut wgpu::CommandEncoder) {
        if !self.pending {
            encoder.resolve_query_set(&self.queries, 0..2, &self.resolve, 0);
            encoder.copy_buffer_to_buffer(&self.resolve, 0, &self.readback, 0, 16);
        }
    }

    pub fn submitted(&mut self) {
        if !self.pending {
            self.pending = true;
            let sender = self.sender.clone();
            self.readback
                .slice(..)
                .map_async(wgpu::MapMode::Read, move |result| {
                    let _ = sender.try_send(result);
                });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timestamp_conversion_rejects_reset_counters_and_invalid_periods() {
        assert_eq!(elapsed_ms(100, 2_000_100, 1.0), Some(2.0));
        assert_eq!(elapsed_ms(100, 100, 1.0), Some(0.0));
        assert_eq!(elapsed_ms(100, 99, 1.0), None);
        assert_eq!(elapsed_ms(0, 100, 0.0), None);
        assert_eq!(elapsed_ms(0, 100, f32::NAN), None);
    }
}
