use std::io::Write;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

/// A single opt-in capture of this renderer's output, with asynchronous GPU
/// readback and file writing. Existing files are never overwritten.
pub struct Capture {
    path: Option<PathBuf>,
    after: Duration,
    start: Instant,
    pending: Arc<AtomicBool>,
}
pub struct Pending {
    buffer: Arc<wgpu::Buffer>,
    path: PathBuf,
    width: u32,
    height: u32,
    pitch: u32,
    rgba: bool,
    done: Arc<AtomicBool>,
}

impl Capture {
    pub fn from_env() -> Option<Self> {
        let path = std::env::var_os("WYRAM_FRAME_CAPTURE")?;
        let ms = std::env::var("WYRAM_FRAME_CAPTURE_AFTER_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&v| v <= 120_000)
            .unwrap_or(20_000);
        Some(Self {
            path: Some(path.into()),
            after: Duration::from_millis(ms),
            start: Instant::now(),
            pending: Arc::new(AtomicBool::new(false)),
        })
    }
    pub fn poll(&self, device: &wgpu::Device) {
        if self.pending.load(Ordering::Relaxed) {
            let _ = device.poll(wgpu::PollType::Poll);
        }
    }
    pub fn record(
        &mut self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        texture: &wgpu::Texture,
    ) -> Option<Pending> {
        if self.path.is_none() || self.start.elapsed() < self.after {
            return None;
        }
        let path = self.path.take().unwrap();
        let rgba = match texture.format() {
            wgpu::TextureFormat::Rgba8Unorm | wgpu::TextureFormat::Rgba8UnormSrgb => true,
            wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb => false,
            _ => {
                eprintln!("Frame capture requires an 8-bit RGBA or BGRA surface");
                return None;
            }
        };
        let width = texture.width();
        let height = texture.height();
        let pitch = (width * 4).div_ceil(256) * 256;
        let size = u64::from(pitch) * u64::from(height);
        if size > 64 * 1024 * 1024 {
            eprintln!("Frame capture exceeds its readback bound");
            return None;
        }
        let buffer = Arc::new(device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Frame capture readback"),
            size,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        }));
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(pitch),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.pending.store(true, Ordering::Relaxed);
        Some(Pending {
            buffer,
            path,
            width,
            height,
            pitch,
            rgba,
            done: Arc::clone(&self.pending),
        })
    }
}

impl Pending {
    pub fn submitted(self) {
        let buffer = Arc::clone(&self.buffer);
        buffer
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                std::thread::spawn(move || {
                    let result = result.map_err(std::io::Error::other).and_then(|()| {
                        let bytes = self
                            .buffer
                            .slice(..)
                            .get_mapped_range()
                            .map_err(std::io::Error::other)?;
                        let bmp = bitmap(
                            self.width,
                            self.height,
                            self.pitch as usize,
                            self.rgba,
                            &bytes,
                        );
                        drop(bytes);
                        self.buffer.unmap();
                        std::fs::File::create_new(&self.path)?.write_all(&bmp)
                    });
                    if let Err(error) = result {
                        eprintln!("Frame capture failed: {error}");
                    }
                    self.done.store(false, Ordering::Relaxed);
                });
            });
    }
}

fn bitmap(width: u32, height: u32, pitch: usize, rgba: bool, bytes: &[u8]) -> Vec<u8> {
    let length = 54 + width as usize * height as usize * 4;
    let mut out = Vec::with_capacity(length);
    out.extend(b"BM");
    out.extend((length as u32).to_le_bytes());
    out.extend([0u8; 4]);
    out.extend(54u32.to_le_bytes());
    out.extend(40u32.to_le_bytes());
    out.extend((width as i32).to_le_bytes());
    out.extend((-(height as i32)).to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(32u16.to_le_bytes());
    out.extend([0u8; 24]);
    for row in bytes.chunks_exact(pitch).take(height as usize) {
        for pixel in row[..width as usize * 4].as_chunks::<4>().0 {
            out.extend(if rgba {
                [pixel[2], pixel[1], pixel[0], 255]
            } else {
                [pixel[0], pixel[1], pixel[2], 255]
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capture_removes_gpu_row_padding_and_preserves_color_and_row_orientation() {
        let pixels = [255, 0, 0, 255, 9, 9, 9, 9, 0, 0, 255, 255, 8, 8, 8, 8];
        let bmp = bitmap(1, 2, 8, true, &pixels);
        assert_eq!(&bmp[..2], b"BM");
        assert_eq!(bmp.len(), 62);
        assert_eq!(&bmp[22..26], &(-2i32).to_le_bytes());
        assert_eq!(&bmp[54..], &[0, 0, 255, 255, 255, 0, 0, 255]);
        assert_eq!(
            &bitmap(1, 2, 8, false, &pixels)[54..],
            &[255, 0, 0, 255, 0, 0, 255, 255]
        );
    }
}
