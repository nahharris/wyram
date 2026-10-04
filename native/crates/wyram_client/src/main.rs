mod animation;
mod camera;
mod characters;
mod chunk_mesh;
mod chunk_wire;
mod flight_input;
mod frustum;
mod gpu_timer;
mod lod_client;
#[cfg(test)]
#[path = "lod_control_tests.rs"]
mod lod_control_tests;
mod lod_coverage;
mod lod_mesh;
mod lod_runtime;
mod lod_transparency;
mod lod_wire;
mod meshing;
mod outbound;
mod replica;
mod rig;
mod telemetry;
mod transparency;
mod world;

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{self, Read};
use std::sync::Arc;
use std::time::{Duration, Instant};

use glam::{Mat4, Vec3};
use serde::{Deserialize, Serialize};
use wgpu::util::DeviceExt;
use winit::application::ApplicationHandler;
use winit::event::{DeviceEvent, ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{CursorGrabMode, Window, WindowId};

use crate::meshing::MeshPipeline;
use crate::replica::{Replica, Snapshot};
use crate::telemetry::{FrameSample, FrameTelemetry};
use crate::world::{RenderDescriptor, Vertex, VoxelWorld};

const MAX_PENDING_LOD_CONTROL_ITEMS: usize = 1024;
const LOD_ACK_FRAME_BUDGET: usize = 128;
type LodAckItem = (u8, i32, i32, i32, u64, bool);
type LodNeedItem = (u8, i32, i32, i32);

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerPacket {
    LodConfig {
        #[serde(flatten)]
        config: lod_runtime::LodConfig,
    },
    LodPlan {
        epoch: u64,
        serial: u64,
        center: [i32; 3],
        keys: Vec<[i32; 4]>,
    },
    LodInvalidate {
        epoch: u64,
        tiles: Vec<(u8, i32, i32, i32, u64)>,
    },
    #[serde(skip)]
    LodTiles {
        batch: lod_wire::WireBatch,
    },
    CharacterStates {
        characters: Vec<Snapshot>,
    },
    Teleport {
        x: f32,
        y: f32,
        z: f32,
        yaw: f32,
        pitch: f32,
    },
    Hello {
        colors: HashMap<String, [u8; 3]>,
        descriptors: HashMap<String, RenderDescriptor>,
        noncolliding: Vec<u16>,
        placeable: Vec<u16>,
        characters: Vec<Snapshot>,
        #[serde(default)]
        models: Vec<rig::Source>,
    },
    Chunk {
        key: [i32; 3],
        revision: u64,
        data: String,
    },
    Chunks {
        chunks: Vec<ChunkPacket>,
    },
    #[serde(skip)]
    PackedChunks {
        chunks: Vec<chunk_wire::PackedChunk>,
    },
    Forget {
        key: [i32; 3],
    },
    ForgetChunks {
        keys: Vec<[i32; 3]>,
    },
}

#[derive(Debug, Deserialize)]
struct ChunkPacket {
    key: [i32; 3],
    revision: u64,
    data: String,
}

#[derive(Clone, Copy, PartialEq, Serialize)]
struct Intent {
    forward: f32,
    right: f32,
    yaw: f32,
    pitch: f32,
    running: bool,
    jump: bool,
    flight_request: u64,
    sneaking: bool,
    crawling: bool,
    climbing: bool,
    rolling: bool,
    cancel_actions: bool,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientPacket {
    Capabilities {
        chunk_protocol: u8,
        forget_protocol: u8,
        lod_protocol: u8,
        available_parallelism: Option<usize>,
    },
    LodAck {
        epoch: u64,
        tiles: Vec<(u8, i32, i32, i32, u64, bool)>,
    },
    LodNeed {
        epoch: u64,
        keys: Vec<(u8, i32, i32, i32)>,
    },
    Input {
        sequence: u64,
        epoch: u64,
        #[serde(flatten)]
        intent: Intent,
    },
    Edit {
        x: i32,
        y: i32,
        z: i32,
        id: u16,
    },
}

#[derive(Debug)]
enum UserEvent {
    PacketReady,
    Disconnected,
}

struct ReceivedPacket {
    packet: ServerPacket,
    decode_cpu_ms: f64,
    wire_bytes: usize,
    queued_at: Instant,
}

fn start_reader(proxy: EventLoopProxy<UserEvent>) -> std::sync::mpsc::Receiver<ReceivedPacket> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(32);
    std::thread::spawn(move || {
        let mut input = io::stdin().lock();
        loop {
            let mut prefix = [0u8; 4];
            if input.read_exact(&mut prefix).is_err() {
                let _ = proxy.send_event(UserEvent::Disconnected);
                break;
            }
            let length = u32::from_be_bytes(prefix) as usize;
            if length > 4 * 1024 * 1024 {
                let _ = proxy.send_event(UserEvent::Disconnected);
                break;
            }
            let mut bytes = vec![0u8; length];
            if input.read_exact(&mut bytes).is_err() {
                let _ = proxy.send_event(UserEvent::Disconnected);
                break;
            }
            let start = Instant::now();
            if let Some(packet) = decode_packet(&bytes) {
                let packet = ReceivedPacket {
                    packet,
                    decode_cpu_ms: start.elapsed().as_secs_f64() * 1000.0,
                    wire_bytes: length,
                    queued_at: Instant::now(),
                };
                if sender.send(packet).is_err() || proxy.send_event(UserEvent::PacketReady).is_err()
                {
                    break;
                }
            }
        }
    });
    receiver
}

fn decode_packet(bytes: &[u8]) -> Option<ServerPacket> {
    use base64::Engine;
    if bytes.starts_with(b"WYC1") {
        return chunk_wire::decode(bytes)
            .ok()
            .map(|chunks| ServerPacket::PackedChunks { chunks });
    }
    if bytes.starts_with(b"WL01") {
        return lod_wire::decode(bytes)
            .ok()
            .map(|batch| ServerPacket::LodTiles { batch });
    }
    let packet: ServerPacket = serde_json::from_slice(bytes).ok()?;
    let chunks = match packet {
        ServerPacket::LodConfig { ref config } if !config.validate() => return None,
        ServerPacket::LodPlan { ref keys, .. }
            if keys.len() > 4608
                || keys.iter().any(|k| {
                    u8::try_from(k[0])
                        .ok()
                        .and_then(|size| {
                            wyram_core::lod::TileKey::new(size, [k[1], k[2], k[3]]).ok()
                        })
                        .is_none()
                }) =>
        {
            return None;
        }
        ServerPacket::LodInvalidate { ref tiles, .. }
            if tiles.len() > 128
                || tiles
                    .iter()
                    .any(|k| wyram_core::lod::TileKey::new(k.0, [k.1, k.2, k.3]).is_err()) =>
        {
            return None;
        }
        ServerPacket::ForgetChunks { ref keys } if keys.len() > 16 => return None,
        ServerPacket::Chunk {
            key,
            revision,
            data,
        } => vec![ChunkPacket {
            key,
            revision,
            data,
        }],
        ServerPacket::Chunks { chunks } if chunks.len() <= 16 => chunks,
        ServerPacket::Chunks { .. } => return None,
        packet => return Some(packet),
    };
    let chunks = chunks
        .into_iter()
        .filter_map(|chunk| {
            let data = base64::engine::general_purpose::STANDARD
                .decode(chunk.data)
                .ok()?;
            if data.len() != wyram_core::BYTE_COUNT {
                return None;
            }
            Some(chunk_wire::PackedChunk {
                key: chunk.key,
                revision: chunk.revision,
                data,
            })
        })
        .collect();
    Some(ServerPacket::PackedChunks { chunks })
}

struct Graphics {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    pipeline: wgpu::RenderPipeline,
    blended_pipeline: wgpu::RenderPipeline,
    lod_pipeline: wgpu::RenderPipeline,
    lod_blended_pipeline: wgpu::RenderPipeline,
    character_pipeline: wgpu::RenderPipeline,
    blended: transparency::BlendedMeshes,
    combined_blended: lod_transparency::CombinedTransparency,
    depth: wgpu::TextureView,
    camera: wgpu::Buffer,
    camera_group: wgpu::BindGroup,
    coverage_mask: wgpu::Buffer,
    meshes: HashMap<[i32; 3], (wgpu::Buffer, u32)>,
    near_ready: HashSet<[i32; 3]>,
    culling: bool,
    fog_enabled: bool,
    gpu_timer: Option<gpu_timer::GpuTimer>,
    characters: wgpu::Buffer,
}

impl Graphics {
    fn new(window: Arc<Window>) -> Result<Self, String> {
        let instance = wgpu::Instance::default();
        let surface = instance
            .create_surface(window.clone())
            .map_err(|error| error.to_string())?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|error| error.to_string())?;
        let timing = std::env::var_os("WYRAM_CLIENT_METRICS").is_some()
            && adapter.features().contains(wgpu::Features::TIMESTAMP_QUERY);
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("Wyram device"),
            required_features: if timing {
                wgpu::Features::TIMESTAMP_QUERY
            } else {
                wgpu::Features::empty()
            },
            required_limits: wgpu::Limits::default(),
            experimental_features: wgpu::ExperimentalFeatures::disabled(),
            memory_hints: wgpu::MemoryHints::MemoryUsage,
            trace: wgpu::Trace::Off,
        }))
        .map_err(|error| error.to_string())?;
        let size = window.inner_size();
        let mut config = surface
            .get_default_config(&adapter, size.width.max(1), size.height.max(1))
            .ok_or("GPU surface is unavailable")?;
        config.desired_maximum_frame_latency = 2;
        surface.configure(&device, &config);
        let culling = std::env::var("WYRAM_FRUSTUM_CULLING").as_deref() != Ok("0");
        if let Some(path) = std::env::var_os("WYRAM_CLIENT_METRICS") {
            let info = adapter.get_info();
            let metadata = serde_json::json!({ "adapter": info.name, "vendor": info.vendor,
                "device": info.device, "backend": format!("{:?}", info.backend), "driver": info.driver,
                "driver_info": info.driver_info, "width": config.width, "height": config.height,
                "present_mode": format!("{:?}", config.present_mode), "timestamp_queries": timing,
                "culling": culling, "mesh_upload_limit": meshing::upload_limit(),
                "chunk_protocol": std::env::var("WYRAM_CHUNK_PROTOCOL").as_deref() != Ok("0") });
            let path = std::path::Path::new(&path).with_extension("adapter.json");
            match std::fs::File::create_new(path)
                .and_then(|file| serde_json::to_writer(file, &metadata).map_err(io::Error::other))
            {
                Ok(()) => {}
                Err(error) => eprintln!("GPU capture metadata unavailable: {error}"),
            }
        }
        let gpu_timer = timing.then(|| gpu_timer::GpuTimer::new(&device, &queue));
        let camera = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Camera matrix"),
            contents: bytemuck::bytes_of(&lod_runtime::CameraUniform::disabled(Mat4::IDENTITY)),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let camera_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Camera layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(128),
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage { read_only: true },
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(16),
                    },
                    count: None,
                },
            ],
        });
        let coverage_mask = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("LOD coverage mask"),
            size: lod_runtime::MASK_BYTES,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let camera_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Camera"),
            layout: &camera_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: camera.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: coverage_mask.as_entire_binding(),
                },
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Voxel pipeline layout"),
            bind_group_layouts: &[Some(&camera_layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::include_wgsl!("shader.wgsl"));
        let make_pipeline = |blended, lod, character| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("Voxel pipeline"),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some(if lod {
                        "vs_lod"
                    } else if character {
                        "vs_character"
                    } else {
                        "vs_main"
                    }),
                    compilation_options: Default::default(),
                    buffers: &[Some(if lod {
                        lod_mesh::LodVertex::layout()
                    } else {
                        Vertex::layout()
                    })],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fs_main"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: config.format,
                        blend: if blended {
                            Some(wgpu::BlendState::ALPHA_BLENDING)
                        } else {
                            None
                        },
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState {
                    cull_mode: None,
                    ..Default::default()
                },
                depth_stencil: Some(wgpu::DepthStencilState {
                    format: wgpu::TextureFormat::Depth32Float,
                    depth_write_enabled: Some(!blended),
                    depth_compare: Some(wgpu::CompareFunction::Less),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        };
        let pipeline = make_pipeline(false, false, false);
        let blended_pipeline = make_pipeline(true, false, false);
        let lod_pipeline = make_pipeline(false, true, false);
        let lod_blended_pipeline = make_pipeline(true, true, false);
        let character_pipeline = make_pipeline(false, false, true);
        let depth = Self::create_depth(&device, &config);
        let characters = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Character vertex batch"),
            size: (rig::MAX_VERTICES * size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        Ok(Self {
            surface,
            device,
            queue,
            config,
            pipeline,
            blended_pipeline,
            lod_pipeline,
            lod_blended_pipeline,
            character_pipeline,
            blended: transparency::BlendedMeshes::default(),
            combined_blended: lod_transparency::CombinedTransparency::default(),
            depth,
            camera,
            camera_group,
            coverage_mask,
            meshes: HashMap::new(),
            near_ready: HashSet::new(),
            culling,
            fog_enabled: std::env::var("WYRAM_LOD_FOG").as_deref() != Ok("0"),
            gpu_timer,
            characters,
        })
    }

    fn create_depth(
        device: &wgpu::Device,
        config: &wgpu::SurfaceConfiguration,
    ) -> wgpu::TextureView {
        device
            .create_texture(&wgpu::TextureDescriptor {
                label: Some("Depth"),
                size: wgpu::Extent3d {
                    width: config.width,
                    height: config.height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            })
            .create_view(&wgpu::TextureViewDescriptor::default())
    }

    fn resize(&mut self, width: u32, height: u32) {
        self.config.width = width.max(1);
        self.config.height = height.max(1);
        self.surface.configure(&self.device, &self.config);
        self.depth = Self::create_depth(&self.device, &self.config);
    }

    fn replace_mesh(&mut self, key: [i32; 3], vertices: &[Vertex]) {
        self.near_ready.insert(key);
        self.blended.replace(key, vertices);
        let opaque: Vec<_> = vertices
            .iter()
            .filter(|v| v.opacity == 1.0)
            .copied()
            .collect();
        let vertices = opaque.as_slice();
        if vertices.is_empty() {
            self.meshes.remove(&key);
        } else {
            let buffer = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("Chunk mesh"),
                    contents: bytemuck::cast_slice(vertices),
                    usage: wgpu::BufferUsages::VERTEX,
                });
            self.meshes.insert(key, (buffer, vertices.len() as u32));
        }
    }

    fn render(
        &mut self,
        position: Vec3,
        direction: Vec3,
        characters: &[Vertex],
        lod: Option<&lod_runtime::LodRuntime>,
    ) -> FrameSample {
        let mut stats = FrameSample::default();
        if let Some(timer) = &mut self.gpu_timer {
            stats.gpu_render_ms = timer.collect(&self.device);
        }
        let blended_start = Instant::now();
        let blended = if lod.is_some() {
            self.blended.prepare_vertices(&self.device, &self.queue)
        } else {
            self.blended.prepare(&self.device, &self.queue, position)
        };
        stats.blended_write_bytes = blended.bytes;
        stats.blended_collect_cpu_ms = blended.collect_ms;
        stats.blended_sort_cpu_ms = blended.sort_ms;
        stats.blended_write_cpu_ms = blended.write_ms;
        stats.blended_quads = blended.quads;
        stats.blended_prepare_cpu_ms = blended_start.elapsed().as_secs_f64() * 1000.0;
        let characters = &characters[..characters.len().min(rig::MAX_VERTICES)];
        if !characters.is_empty() {
            self.queue
                .write_buffer(&self.characters, 0, bytemuck::cast_slice(characters));
        }
        let aspect = self.config.width as f32 / self.config.height as f32;
        let far = lod.map_or(512.0, |lod| {
            let horizontal =
                lod.config.near_radius as f32 * f32::from(lod.config.max_cell_size) * 16.0 + 16.0;
            let vertical = (position.y - lod.config.min_y as f32)
                .abs()
                .max((position.y - lod.config.max_y as f32).abs());
            horizontal.hypot(vertical) + 16.0
        });
        let matrix = Mat4::perspective_rh(70f32.to_radians(), aspect, 0.05, far)
            * Mat4::look_to_rh(position, direction, Vec3::Y);
        let frustum = frustum::Frustum::new(matrix);
        let far_parts: Vec<_> = lod
            .into_iter()
            .flat_map(|lod| {
                let mut residents: Vec<_> = lod
                    .client
                    .residents()
                    .filter(|r| {
                        r.epoch == lod.epoch && {
                            let origin = r.key.origin().expect("resident tile validated");
                            !self.culling
                                || frustum.intersects_box(
                                    origin.map(|v| v as f32),
                                    origin.map(|v| (v + r.key.span()) as f32),
                                )
                        }
                    })
                    .collect();
                residents.sort_by_key(|r| (r.key.cell_size, r.key.position));
                residents
                    .into_iter()
                    .flat_map(|r| r.parts.iter())
                    .filter(|part| part.blended.is_some())
                    .collect::<Vec<_>>()
            })
            .collect();
        if lod.is_some() {
            let combined = self.combined_blended.prepare(
                &self.device,
                &self.queue,
                position,
                &self.blended,
                &far_parts,
            );
            stats.blended_sort_cpu_ms += combined.sort_ms;
            stats.blended_write_cpu_ms += combined.write_ms;
            stats.blended_write_bytes += combined.bytes;
            stats.blended_quads = combined.quads;
        }
        let mut uniform = lod_runtime::CameraUniform::disabled(matrix);
        if let Some(lod) = lod {
            uniform.eye = position.extend(0.0).to_array();
            uniform.fog = [
                0.0,
                1.0,
                lod.config.near_radius as f32,
                lod.start.elapsed().as_secs_f32(),
            ];
            uniform.anchor = [
                lod.center[2],
                lod.config.near_radius as i32,
                i32::from(lod.config.max_cell_size),
                i32::from(!self.fog_enabled),
            ];
            uniform.grid = [0, 0, 0, lod.center[0]];
            if let Some(frame) = &lod.coverage_frame {
                uniform.fog[0] = frame.frontier_radius_blocks;
                uniform.grid = [
                    frame.origin_chunk[0],
                    frame.origin_chunk[1],
                    frame.side as i32,
                    lod.center[0],
                ];
            }
        }
        self.queue
            .write_buffer(&self.camera, 0, bytemuck::bytes_of(&uniform));
        let acquire_start = Instant::now();
        let acquired = self.surface.get_current_texture();
        stats.surface_acquire_ms = acquire_start.elapsed().as_secs_f64() * 1000.0;
        let frame = match acquired {
            wgpu::CurrentSurfaceTexture::Success(frame) => frame,
            wgpu::CurrentSurfaceTexture::Suboptimal(frame) => {
                self.surface.configure(&self.device, &self.config);
                frame
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
                return stats;
            }
            _ => return stats,
        };
        let encode_start = Instant::now();
        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Frame"),
            });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("World"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.43,
                            g: 0.65,
                            b: 0.86,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &self.depth,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Store,
                    }),
                    stencil_ops: None,
                }),
                timestamp_writes: self.gpu_timer.as_ref().and_then(|timer| timer.writes()),
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.camera_group, &[]);
            for (key, (buffer, count)) in &self.meshes {
                if self.culling && !frustum.intersects_chunk(*key) {
                    continue;
                }
                pass.set_vertex_buffer(0, buffer.slice(..));
                pass.draw(0..*count, 0..1);
                stats.opaque_draws += 1;
                stats.opaque_vertices += *count as usize;
            }
            if !characters.is_empty() {
                pass.set_pipeline(&self.character_pipeline);
                pass.set_vertex_buffer(0, self.characters.slice(..));
                pass.draw(0..characters.len() as u32, 0..1);
            }
            if let Some(lod) = lod {
                pass.set_pipeline(&self.lod_pipeline);
                let visible = |key: wyram_core::lod::TileKey| {
                    let origin = key.origin().expect("resident tile validated");
                    !self.culling
                        || frustum.intersects_box(
                            origin.map(|v| v as f32),
                            origin.map(|v| (v + key.span()) as f32),
                        )
                };
                for resident in lod
                    .client
                    .residents()
                    .filter(|r| r.epoch == lod.epoch && visible(r.key))
                {
                    for part in resident.parts {
                        if let Some((buffer, count)) = &part.opaque {
                            pass.set_vertex_buffer(0, buffer.slice(..));
                            pass.draw(0..*count, 0..1);
                            stats.opaque_draws += 1;
                            stats.opaque_vertices += *count as usize;
                        }
                    }
                }
            }
            if lod.is_some() {
                self.combined_blended.draw(
                    &mut pass,
                    &self.blended,
                    &far_parts,
                    &self.blended_pipeline,
                    &self.lod_blended_pipeline,
                );
            } else {
                pass.set_pipeline(&self.blended_pipeline);
                self.blended.draw(&mut pass);
            }
        }
        if let Some(timer) = &self.gpu_timer {
            timer.resolve(&mut encoder);
        }
        let commands = encoder.finish();
        stats.render_encode_cpu_ms = encode_start.elapsed().as_secs_f64() * 1000.0;
        let submit_start = Instant::now();
        self.queue.submit(Some(commands));
        if let Some(timer) = &mut self.gpu_timer {
            timer.submitted();
        }
        self.queue.present(frame);
        stats.render_submit_cpu_ms = submit_start.elapsed().as_secs_f64() * 1000.0;
        stats
    }
}

struct Game {
    window: Option<Arc<Window>>,
    graphics: Option<Graphics>,
    inbound: Option<std::sync::mpsc::Receiver<ReceivedPacket>>,
    inbound_decode_ms: f64,
    inbound_wire_bytes: usize,
    inbound_queue_max_ms: f64,
    world: VoxelWorld,
    lod: Option<lod_runtime::LodRuntime>,
    session_start: Instant,
    position: Vec3,
    yaw: f32,
    pitch: f32,
    replica: Replica,
    characters: characters::Scene,
    camera: camera::Camera,
    last_intent: Option<Intent>,
    input_sequence: u64,
    last_input: Instant,
    cancel_actions: bool,
    flight_input: flight_input::FlightInput,
    pressed: HashSet<KeyCode>,
    cursor_locked: bool,
    selected: u16,
    placeable: Vec<u16>,
    meshing: MeshPipeline,
    telemetry: FrameTelemetry,
    decode_ms: f64,
    last_redraw: Instant,
    outbound: Option<outbound::Outbound>,
    outbound_error: Option<outbound::SendError>,
    pending_lod_acks: VecDeque<(u64, LodAckItem)>,
    pending_lod_needs: VecDeque<(u64, LodNeedItem)>,
}

impl Game {
    // FIFO admission is bounded by both time and count. Packet-ready events
    // only request a redraw, so a burst cannot postpone rendering indefinitely.
    fn receive_packets(&mut self) {
        self.prune_lod_control();
        let start = Instant::now();
        for _ in 0..32 {
            if start.elapsed() >= Duration::from_millis(1)
                || self.pending_lod_acks.len()
                    >= MAX_PENDING_LOD_CONTROL_ITEMS - LOD_ACK_FRAME_BUDGET
            {
                break;
            }
            let Some(packet) = self.inbound.as_ref().and_then(|r| r.try_recv().ok()) else {
                break;
            };
            self.inbound_decode_ms += packet.decode_cpu_ms;
            self.inbound_wire_bytes += packet.wire_bytes;
            self.inbound_queue_max_ms = self
                .inbound_queue_max_ms
                .max(packet.queued_at.elapsed().as_secs_f64() * 1000.0);
            self.apply_server_packet(packet.packet);
        }
    }

    fn apply_server_packet(&mut self, packet: ServerPacket) {
        match packet {
            ServerPacket::LodConfig { config } => {
                if config.enabled && self.lod.is_none() {
                    match lod_runtime::LodRuntime::new(config, self.session_start) {
                        Ok(lod) => self.lod = Some(lod),
                        Err(error) => eprintln!("LOD configuration failed: {error}"),
                    }
                }
            }
            ServerPacket::LodPlan {
                epoch,
                serial,
                center,
                keys,
            } => {
                if let Some(lod) = &mut self.lod {
                    let teleport = lod.epoch != epoch;
                    let keys = keys
                        .into_iter()
                        .map(|k| {
                            wyram_core::lod::TileKey::new(k[0] as u8, [k[1], k[2], k[3]])
                                .expect("validated plan")
                        })
                        .collect();
                    lod.set_plan(epoch, serial, center, keys, &mut self.world);
                    if teleport && let Some(graphics) = &self.graphics {
                        for key in &graphics.near_ready {
                            lod.near_ready(*key);
                        }
                    }
                }
            }
            ServerPacket::LodInvalidate { epoch, tiles } => {
                if let Some(lod) = &mut self.lod {
                    lod.invalidate(epoch, &tiles);
                }
            }
            ServerPacket::LodTiles { batch } => {
                if let Some(lod) = &mut self.lod {
                    let acks = lod.receive(batch);
                    self.send_lod_acks(acks);
                }
            }
            ServerPacket::PackedChunks { chunks } => {
                let start = Instant::now();
                for chunk in chunks {
                    self.world
                        .receive_packed(chunk.key, chunk.revision, chunk.data);
                }
                self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
            }
            ServerPacket::Teleport {
                x,
                y,
                z,
                yaw,
                pitch,
            } => self.apply_teleport(x, y, z, yaw, pitch),
            ServerPacket::Hello {
                colors,
                descriptors,
                noncolliding,
                placeable,
                characters,
                models,
            } => {
                self.world.set_palette(colors);
                self.world.set_descriptors(descriptors, noncolliding);
                self.placeable = placeable
                    .into_iter()
                    .filter(|id| self.world.has_block_id(*id))
                    .collect();
                self.selected = self.placeable.first().copied().unwrap_or(0);
                self.characters.models(models);
                self.accept_characters(characters);
            }
            ServerPacket::CharacterStates { characters } => self.accept_characters(characters),
            ServerPacket::Chunk {
                key,
                revision,
                data,
            } => {
                let start = Instant::now();
                self.world.receive_chunk(key, revision, &data);
                self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
            }
            ServerPacket::Chunks { chunks } => {
                if chunks.len() <= 16 {
                    let start = Instant::now();
                    for chunk in chunks {
                        self.world
                            .receive_chunk(chunk.key, chunk.revision, &chunk.data);
                    }
                    self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
                }
            }
            ServerPacket::Forget { key } => {
                if let Some(lod) = &mut self.lod {
                    lod.forget_near(key);
                }
                self.world.forget(key);
                if let Some(graphics) = self.graphics.as_mut() {
                    graphics.meshes.remove(&key);
                    graphics.near_ready.remove(&key);
                    graphics.blended.replace(key, &[]);
                }
            }
            ServerPacket::ForgetChunks { keys } => {
                for key in keys {
                    self.apply_server_packet(ServerPacket::Forget { key });
                }
            }
        }
    }

    fn new() -> Self {
        Self {
            window: None,
            graphics: None,
            inbound: None,
            inbound_decode_ms: 0.0,
            inbound_wire_bytes: 0,
            inbound_queue_max_ms: 0.0,
            world: VoxelWorld::default(),
            lod: None,
            session_start: Instant::now(),
            position: Vec3::new(0.5, 73.0, 0.5),
            yaw: 0.0,
            pitch: -0.15,
            replica: Replica::default(),
            characters: characters::Scene::default(),
            camera: camera::Camera::default(),
            last_intent: None,
            input_sequence: 0,
            last_input: Instant::now() - Duration::from_secs(1),
            pressed: HashSet::new(),
            flight_input: flight_input::FlightInput::default(),
            cancel_actions: false,
            cursor_locked: false,
            selected: 1,
            placeable: Vec::new(),
            meshing: MeshPipeline::new(),
            telemetry: FrameTelemetry::from_env(),
            decode_ms: 0.0,
            last_redraw: Instant::now(),
            outbound: None,
            outbound_error: None,
            pending_lod_acks: VecDeque::new(),
            pending_lod_needs: VecDeque::new(),
        }
    }

    fn direction(&self) -> Vec3 {
        Vec3::new(
            self.yaw.sin() * self.pitch.cos(),
            self.pitch.sin(),
            -self.yaw.cos() * self.pitch.cos(),
        )
    }

    fn send_packet(&mut self, packet: ClientPacket) {
        if let Some(outbound) = &self.outbound
            && let Err(error) = outbound.send(packet)
        {
            self.outbound_error = Some(error);
        }
    }

    fn send_lod_acks(&mut self, acks: Vec<(u64, wyram_core::lod::TileKey, u64, bool)>) {
        if self.lod.is_none() {
            return;
        }
        for (epoch, key, revision, ready) in acks {
            let item = (
                key.cell_size,
                key.position[0],
                key.position[1],
                key.position[2],
                revision,
                ready,
            );
            if !self.pending_lod_acks.contains(&(epoch, item))
                && self.pending_lod_acks.len() < MAX_PENDING_LOD_CONTROL_ITEMS
            {
                self.pending_lod_acks.push_back((epoch, item));
            }
        }
    }

    fn queue_lod_needs(&mut self, epoch: u64, keys: Vec<wyram_core::lod::TileKey>) {
        let Some(current_epoch) = self.lod.as_ref().map(|lod| lod.epoch) else {
            return;
        };
        if epoch != current_epoch {
            return;
        }
        let mut restore = Vec::new();
        for key in keys {
            let item = (
                key.cell_size,
                key.position[0],
                key.position[1],
                key.position[2],
            );
            if self.pending_lod_needs.contains(&(epoch, item)) {
                continue;
            }
            if self.pending_lod_needs.len() >= MAX_PENDING_LOD_CONTROL_ITEMS {
                restore.push(key);
            } else {
                self.pending_lod_needs.push_back((epoch, item));
            }
        }
        if !restore.is_empty()
            && let Some(lod) = &mut self.lod
        {
            lod.restore_needs(epoch, restore);
        }
    }

    fn prune_lod_control(&mut self) {
        if let Some(epoch) = self.lod.as_ref().map(|lod| lod.epoch) {
            self.pending_lod_needs
                .retain(|(queued_epoch, _)| *queued_epoch == epoch);
        } else {
            self.pending_lod_acks.clear();
            self.pending_lod_needs.clear();
        }
    }

    fn retry_lod_control(&mut self) {
        self.prune_lod_control();
        let Some(epoch) = self.lod.as_ref().map(|lod| lod.epoch) else {
            return;
        };
        if self.outbound.is_none() {
            return;
        }

        while let Some((queued_epoch, _)) = self.pending_lod_acks.front() {
            let epoch = *queued_epoch;
            let tiles: Vec<_> = self
                .pending_lod_acks
                .iter()
                .take_while(|(queued_epoch, _)| *queued_epoch == epoch)
                .take(16)
                .map(|(_, item)| *item)
                .collect();
            let result =
                self.outbound
                    .as_ref()
                    .expect("outbound was checked")
                    .send(ClientPacket::LodAck {
                        epoch,
                        tiles: tiles.clone(),
                    });
            match result {
                Ok(()) => {
                    for _ in 0..tiles.len() {
                        self.pending_lod_acks.pop_front();
                    }
                }
                Err(outbound::SendError::Full) => break,
                Err(error @ outbound::SendError::Closed) => {
                    self.outbound_error = Some(error);
                    return;
                }
            }
        }

        while let Some((queued_epoch, _)) = self.pending_lod_needs.front() {
            if *queued_epoch != epoch {
                self.pending_lod_needs.pop_front();
                continue;
            }
            let keys: Vec<_> = self
                .pending_lod_needs
                .iter()
                .take_while(|(queued_epoch, _)| *queued_epoch == epoch)
                .take(16)
                .map(|(_, item)| *item)
                .collect();
            let result =
                self.outbound
                    .as_ref()
                    .expect("outbound was checked")
                    .send(ClientPacket::LodNeed {
                        epoch,
                        keys: keys.clone(),
                    });
            match result {
                Ok(()) => {
                    for _ in 0..keys.len() {
                        self.pending_lod_needs.pop_front();
                    }
                }
                Err(outbound::SendError::Full) => break,
                Err(error @ outbound::SendError::Closed) => {
                    self.outbound_error = Some(error);
                    return;
                }
            }
        }
    }

    fn apply_teleport(&mut self, x: f32, y: f32, z: f32, yaw: f32, pitch: f32) {
        self.flight_input.reset_epoch();
        self.position = Vec3::new(x, y, z);
        self.yaw = yaw;
        self.pitch = pitch;
        self.release_input();
    }

    fn release_input(&mut self) {
        self.flight_input.release_controls();
        self.pressed.clear();
        self.cancel_actions = true;
        self.update_input(true);
    }

    fn update_input(&mut self, force: bool) {
        let axis = |positive, negative| {
            f32::from(u8::from(self.pressed.contains(&positive)))
                - f32::from(u8::from(self.pressed.contains(&negative)))
        };
        let intent = Intent {
            forward: axis(KeyCode::KeyW, KeyCode::KeyS),
            right: axis(KeyCode::KeyD, KeyCode::KeyA),
            yaw: self.yaw,
            pitch: self.pitch,
            running: self.pressed.contains(&KeyCode::ControlLeft),
            jump: self.pressed.contains(&KeyCode::Space),
            flight_request: self.flight_input.request,
            sneaking: self.pressed.contains(&KeyCode::ShiftLeft),
            crawling: self.pressed.contains(&KeyCode::KeyC),
            climbing: false,
            rolling: self.pressed.contains(&KeyCode::KeyQ),
            cancel_actions: self.cancel_actions,
        };
        if force
            || self.last_intent != Some(intent)
            || self.last_input.elapsed() >= Duration::from_millis(100)
        {
            self.input_sequence += 1;
            self.send_packet(ClientPacket::Input {
                sequence: self.input_sequence,
                epoch: self.replica.epoch(),
                intent,
            });
            self.last_intent = Some(intent);
            self.last_input = Instant::now();
        }
    }

    fn accept_characters(&mut self, characters: Vec<Snapshot>) {
        if let Some(snapshot) = self.characters.receive(characters) {
            let reset = snapshot.epoch != self.replica.epoch();
            let (x, y, z, yaw, pitch) = (
                snapshot.x,
                snapshot.y,
                snapshot.z,
                snapshot.yaw,
                snapshot.pitch,
            );
            if self.replica.accept(snapshot) {
                if reset {
                    self.apply_teleport(x, y, z, yaw, pitch);
                }
                self.position = Vec3::new(x, y, z);
            }
        }
    }

    fn step(&mut self) {
        self.update_input(false);
        self.position = self.replica.sample(&self.world);
    }
    fn edit(&mut self, place: bool) {
        let mut previous = None;
        for step in 1..=60 {
            let point = self.position + self.direction() * (step as f32 * 0.1);
            let key = (
                point.x.floor() as i32,
                point.y.floor() as i32,
                point.z.floor() as i32,
            );
            if self.world.selects(point) {
                let target = if place { previous.unwrap_or(key) } else { key };
                self.send_packet(ClientPacket::Edit {
                    x: target.0,
                    y: target.1,
                    z: target.2,
                    id: if place { self.selected } else { 0 },
                });
                break;
            }
            previous = Some(key);
        }
    }
}

impl ApplicationHandler<UserEvent> for Game {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attributes = Window::default_attributes()
            .with_title("Wyram")
            .with_inner_size(winit::dpi::LogicalSize::new(1280.0, 720.0));
        match event_loop.create_window(attributes) {
            Ok(window) => {
                let window = Arc::new(window);
                match Graphics::new(window.clone()) {
                    Ok(graphics) => {
                        self.graphics = Some(graphics);
                        self.window = Some(window);
                    }
                    Err(error) => {
                        eprintln!("graphics initialization failed: {error}");
                        event_loop.exit();
                    }
                }
            }
            Err(error) => {
                eprintln!("window creation failed: {error}");
                event_loop.exit();
            }
        }
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UserEvent) {
        match event {
            UserEvent::PacketReady => {
                if let Some(window) = &self.window {
                    window.request_redraw();
                }
            }
            UserEvent::Disconnected => event_loop.exit(),
        }
    }
    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        if self.window.as_ref().map(|window| window.id()) != Some(id) {
            return;
        }
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Focused(false) => self.release_input(),
            WindowEvent::Resized(size) => {
                if let Some(graphics) = self.graphics.as_mut() {
                    graphics.resize(size.width, size.height);
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if let PhysicalKey::Code(code) = event.physical_key {
                    match event.state {
                        ElementState::Pressed => {
                            if code == KeyCode::F5 {
                                if !event.repeat {
                                    self.camera.cycle();
                                }
                                return;
                            }
                            if code == KeyCode::Space {
                                self.flight_input.press_space(
                                    Instant::now(),
                                    event.repeat || self.pressed.contains(&code),
                                );
                            }
                            self.cancel_actions = false;
                            self.pressed.insert(code);
                            if code == KeyCode::Escape {
                                self.cursor_locked = false;
                                self.release_input();
                                if let Some(window) = &self.window {
                                    let _ = window.set_cursor_grab(CursorGrabMode::None);
                                    window.set_cursor_visible(true);
                                }
                            }
                            let number = match code {
                                KeyCode::Digit1 => Some(1),
                                KeyCode::Digit2 => Some(2),
                                KeyCode::Digit3 => Some(3),
                                KeyCode::Digit4 => Some(4),
                                KeyCode::Digit5 => Some(5),
                                KeyCode::Digit6 => Some(6),
                                KeyCode::Digit7 => Some(7),
                                KeyCode::Digit8 => Some(8),
                                KeyCode::Digit9 => Some(9),
                                _ => None,
                            };
                            if let Some(index) = number
                                && let Some(id) = self.placeable.get(index - 1)
                            {
                                self.selected = *id;
                            }
                        }
                        ElementState::Released => {
                            self.pressed.remove(&code);
                        }
                    }
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                if self.cursor_locked && self.camera.mode != camera::Mode::First {
                    let amount = match delta {
                        MouseScrollDelta::LineDelta(_, y) => y,
                        MouseScrollDelta::PixelDelta(p) => p.y as f32 / 40.,
                    };
                    self.camera.zoom(amount);
                }
            }
            WindowEvent::MouseInput {
                state: ElementState::Pressed,
                button,
                ..
            } => {
                if !self.cursor_locked {
                    if let Some(window) = &self.window {
                        self.cursor_locked = window.set_cursor_grab(CursorGrabMode::Locked).is_ok();
                        window.set_cursor_visible(!self.cursor_locked);
                    }
                } else if button == MouseButton::Left || button == MouseButton::Right {
                    self.edit(button == MouseButton::Right);
                }
            }
            WindowEvent::RedrawRequested => {
                let start = Instant::now();
                let frame_ms = (start - self.last_redraw).as_secs_f64() * 1000.0;
                self.last_redraw = start;
                self.receive_packets();
                self.step();
                let direction = self.direction();
                let radius = self.replica.state.as_ref().map_or(0.28, |s| s.radius);
                let eye = self.camera.eye(
                    self.position,
                    self.replica.state.as_ref(),
                    (frame_ms / 1000.) as f32,
                    &self.world,
                );
                let view = self.camera.view_at(
                    eye,
                    direction,
                    self.world.aim_point(self.position, direction),
                    &self.world,
                    radius,
                );
                let character_vertices = self.characters.vertices(
                    &self.replica,
                    &self.world,
                    view.show_player,
                    (frame_ms / 1000.) as f32,
                );
                if let Some(graphics) = self.graphics.as_mut() {
                    let center = [self.position.x, self.position.y, self.position.z]
                        .map(|v| (v.floor() as i32).div_euclid(16));
                    let stats = self
                        .meshing
                        .update(&mut self.world, center, |key, vertices| {
                            graphics.replace_mesh(key, vertices);
                            if let Some(lod) = &mut self.lod {
                                lod.near_ready(key);
                            }
                        });
                    let acks = if let Some(lod) = &mut self.lod {
                        lod.update(
                            &self.world,
                            &graphics.device,
                            &graphics.queue,
                            &graphics.coverage_mask,
                            self.world.dirty_count() != 0 || self.meshing.in_flight() != 0,
                        )
                    } else {
                        Vec::new()
                    };
                    let needs = self.lod.as_mut().map(|lod| (lod.epoch, lod.drain_needs()));
                    let render_stats = graphics.render(
                        view.position,
                        view.direction,
                        &character_vertices,
                        self.lod.as_ref(),
                    );
                    let outbound = self
                        .outbound
                        .as_ref()
                        .map(|writer| writer.snapshot())
                        .unwrap_or_default();
                    self.telemetry.record(FrameSample {
                        frame_ms,
                        redraw_cpu_ms: start.elapsed().as_secs_f64() * 1000.0,
                        decode_ms: std::mem::take(&mut self.decode_ms),
                        inbound_decode_ms: std::mem::take(&mut self.inbound_decode_ms),
                        inbound_wire_bytes: std::mem::take(&mut self.inbound_wire_bytes),
                        inbound_queue_max_ms: std::mem::take(&mut self.inbound_queue_max_ms),
                        worker_mesh_ms: stats.mesh_ms,
                        upload_cpu_ms: stats.upload_ms,
                        uploaded_meshes: stats.uploads,
                        uploaded_bytes: stats.upload_bytes,
                        stale_meshes: stats.stale,
                        loaded_chunks: self.world.chunk_count(),
                        dirty_chunks: self.world.dirty_count(),
                        in_flight: self.meshing.in_flight(),
                        lod_gpu_bytes: self.lod.as_ref().map_or(0, |lod| lod.client.gpu_bytes()),
                        lod_reserved_gpu_bytes: self
                            .lod
                            .as_ref()
                            .map_or(0, |lod| lod.client.reserved_gpu_bytes()),
                        lod_encoded_cache_bytes: self
                            .lod
                            .as_ref()
                            .map_or(0, |lod| lod.client.cache_bytes()),
                        lod_mesh_jobs: self.lod.as_ref().map_or(0, |lod| lod.client.running_jobs()),
                        lod_pending_tiles: self.lod.as_ref().map_or(0, |lod| lod.pending_tiles()),
                        lod_resident_tiles: self
                            .lod
                            .as_ref()
                            .map_or(0, |lod| lod.client.residents().count()),
                        lod_frontier_blocks: self
                            .lod
                            .as_ref()
                            .and_then(|lod| lod.coverage_frame.as_ref())
                            .map_or(0.0, |frame| frame.frontier_radius_blocks),
                        outbound_queued: outbound.queued,
                        outbound_sent: outbound.sent,
                        outbound_coalesced_inputs: outbound.coalesced_inputs,
                        outbound_queue_max_ms: outbound.queue_max_ms,
                        outbound_write_max_ms: outbound.write_max_ms,
                        ..render_stats
                    });
                    self.send_lod_acks(acks);
                    if let Some((epoch, keys)) = needs
                        && !keys.is_empty()
                    {
                        self.queue_lod_needs(epoch, keys);
                    }
                }
                self.retry_lod_control();
            }
            _ => {}
        }
    }

    fn device_event(
        &mut self,
        _event_loop: &ActiveEventLoop,
        _id: winit::event::DeviceId,
        event: DeviceEvent,
    ) {
        if self.cursor_locked
            && let DeviceEvent::MouseMotion { delta } = event
        {
            self.yaw = (self.yaw + delta.0 as f32 * 0.002).rem_euclid(std::f32::consts::TAU);
            self.pitch = (self.pitch - delta.1 as f32 * 0.002).clamp(-1.55, 1.55);
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        if self.outbound_error.is_some() {
            event_loop.exit();
            return;
        }
        if let Some(window) = &self.window {
            window.request_redraw();
        }
    }
}

fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "--validate-models") {
        match args
            .get(2)
            .ok_or("missing model file".to_string())
            .and_then(|path| rig::validate_file(path))
        {
            Ok(count) => println!("validated {count} character models"),
            Err(reason) => {
                eprintln!("model import failed: {reason}");
                std::process::exit(2);
            }
        }
        return;
    }
    let event_loop = EventLoop::<UserEvent>::with_user_event()
        .build()
        .expect("event loop creation failed");
    let inbound = start_reader(event_loop.create_proxy());
    let mut game = Game::new();
    game.inbound = Some(inbound);
    let proxy = event_loop.create_proxy();
    let (outbound, _worker) = outbound::Outbound::start(io::stdout(), move |error| {
        let _ = proxy.send_event(UserEvent::Disconnected);
        eprintln!("engine connection write failed: {error}");
    });
    game.outbound = Some(outbound);
    game.send_packet(ClientPacket::Capabilities {
        chunk_protocol: u8::from(std::env::var("WYRAM_CHUNK_PROTOCOL").as_deref() != Ok("0")),
        forget_protocol: 1,
        lod_protocol: 1,
        available_parallelism: std::thread::available_parallelism().ok().map(usize::from),
    });
    event_loop
        .run_app(&mut game)
        .expect("game event loop failed");
    if let Some(error) = game.outbound_error {
        eprintln!(
            "engine send queue failed ({error:?}); session ended, pending edits may be undelivered"
        );
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn unload_batches_are_bounded_and_keep_legacy_support() {
        let packet = serde_json::json!({"type":"forget_chunks","keys":[[-1,-12,0],[0,19,0]]});
        assert!(super::decode_packet(&serde_json::to_vec(&packet).unwrap()).is_some());
        let oversized = serde_json::json!({"type":"forget_chunks","keys":vec![[0,0,0];17]});
        assert!(super::decode_packet(&serde_json::to_vec(&oversized).unwrap()).is_none());
        assert!(super::decode_packet(br#"{"type":"forget","key":[0,0,0]}"#).is_some());
    }

    #[test]
    fn inbound_bursts_leave_work_for_the_next_frame_in_wire_order() {
        let (sender, receiver) = std::sync::mpsc::channel();
        let mut game = super::Game::new();
        let count = 100;
        for x in 0..count {
            game.world
                .receive_packed([x, 0, 0], 0, vec![0; wyram_core::BYTE_COUNT]);
            sender
                .send(super::ReceivedPacket {
                    packet: super::ServerPacket::Forget { key: [x, 0, 0] },
                    decode_cpu_ms: 0.0,
                    wire_bytes: 0,
                    queued_at: std::time::Instant::now(),
                })
                .unwrap();
        }
        game.inbound = Some(receiver);
        game.receive_packets();
        let remaining = game.world.chunk_count();
        assert!(remaining > 0 && remaining < count as usize);
        assert!(game.world.mesh_job([0, 0, 0]).is_none());
        assert!(game.world.mesh_job([count - 1, 0, 0]).is_some());
        while game.world.chunk_count() > 0 {
            game.receive_packets();
        }
    }

    #[test]
    fn background_decode_preserves_json_packed_parity_and_skips_bad_entries() {
        use base64::Engine;
        let data = vec![7; wyram_core::BYTE_COUNT];
        let encoded = base64::engine::general_purpose::STANDARD.encode(&data);
        let json = serde_json::to_vec(&serde_json::json!({"type":"chunks", "chunks":[
            {"key":[-1,-12,0],"revision":9,"data":encoded},
            {"key":[0,19,0],"revision":2,"data":"invalid"}
        ]}))
        .unwrap();
        let Some(super::ServerPacket::PackedChunks { chunks }) = super::decode_packet(&json) else {
            panic!("JSON chunks lost");
        };
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].key, [-1, -12, 0]);
        assert_eq!(chunks[0].revision, 9);
        assert_eq!(chunks[0].data, data);
        assert!(super::decode_packet(b"WYC1\0\x01").is_none());
    }

    #[test]
    fn decodes_chunk_batches_at_negative_and_high_world_layers() {
        let packet = serde_json::json!({"type":"chunks","chunks":[{"key":[-1,-12,0],"revision":0,"data":""},{"key":[0,19,0],"revision":2,"data":""}]});
        assert!(serde_json::from_value::<super::ServerPacket>(packet).is_ok());
    }
    use super::*;
    #[test]
    fn releasing_input_sends_idle_intent_with_current_epoch() {
        let (outbound, worker) =
            outbound::Outbound::start(Vec::<u8>::new(), |_| panic!("write failed"));
        let mut game = Game::new();
        game.outbound = Some(outbound);
        game.pressed.insert(KeyCode::ControlLeft);
        game.pressed.insert(KeyCode::ShiftLeft);
        game.pressed.insert(KeyCode::KeyC);
        game.pressed.insert(KeyCode::KeyE);
        game.pressed.insert(KeyCode::KeyQ);
        game.release_input();
        game.update_input(false);
        assert!(game.pressed.is_empty());
        drop(game);
        let bytes = worker.join().unwrap().unwrap();
        let length = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
        assert_eq!(bytes.len(), length + 4);
        let packet: serde_json::Value = serde_json::from_slice(&bytes[4..]).unwrap();
        assert_eq!(packet["type"], "input");
        assert_eq!(packet["running"], false);
        assert_eq!(packet["sneaking"], false);
        assert_eq!(packet["crawling"], false);
        assert_eq!(packet["climbing"], false);
        assert_eq!(packet["rolling"], false);
        assert_eq!(packet["cancel_actions"], true);
        assert_eq!(packet["forward"], 0.0);
    }
    #[test]
    fn raw_keys_cannot_move_a_player_without_authoritative_state() {
        let mut game = Game::new();
        game.pressed.insert(KeyCode::KeyW);
        game.pressed.insert(KeyCode::ControlLeft);
        game.step();
        assert_eq!(game.position, Vec3::new(0.5, 73.0, 0.5));
    }
    #[test]
    fn teleport_resets_held_input_and_repositions_player() {
        let mut game = Game::new();
        game.pressed.insert(KeyCode::KeyW);
        game.apply_teleport(32.5, 90.0, -7.5, 1.0, -0.25);
        assert_eq!(game.position, Vec3::new(32.5, 90.0, -7.5));
        assert!(game.pressed.is_empty());
    }
    #[test]
    fn all_camera_modes_preserve_the_character_edit_ray_and_reach() {
        use base64::Engine;
        for place in [false, true] {
            let mut targets = Vec::new();
            for mode in [
                camera::Mode::First,
                camera::Mode::Third,
                camera::Mode::Front,
            ] {
                let (outbound, worker) =
                    outbound::Outbound::start(Vec::<u8>::new(), |_| panic!("write failed"));
                let mut game = Game::new();
                game.outbound = Some(outbound);
                game.camera.mode = mode;
                game.position = Vec3::new(8.5, 3.5, 8.5);
                game.pitch = 0.;
                game.yaw = 0.;
                let mut bytes = vec![0; wyram_core::BYTE_COUNT];
                bytes[((3 * 16 + 4) * 16 + 8) * 2] = 1;
                game.world.receive_chunk(
                    [0, 0, 0],
                    1,
                    &base64::engine::general_purpose::STANDARD.encode(bytes),
                );
                let original = game.position;
                let direction = game.direction();
                let _ = game
                    .camera
                    .view(game.position, direction, &game.world, 0.28);
                assert_eq!(game.position, original);
                assert_eq!(game.direction(), direction);
                game.edit(place);
                drop(game);
                let data = worker.join().unwrap().unwrap();
                let packet: serde_json::Value = serde_json::from_slice(&data[4..]).unwrap();
                targets.push(packet);
            }
            assert_eq!(targets[0], targets[1]);
            assert_eq!(targets[0], targets[2]);
            assert_eq!(targets[0]["z"], if place { 5 } else { 4 });
        }
    }
    #[test]
    fn flight_gestures_survive_snapshots_until_the_teleport_epoch_changes() {
        let snapshot = |sequence, epoch| {
            serde_json::from_value(serde_json::json!({"id":"player","x":0.5,"y":1.62,"z":0.5,"feet":[0.5,0.0,0.5],"velocity":[0.0,0.0,0.0],"radius":0.28,"height":1.8,"eye_height":1.62,"yaw":0.0,"pitch":0.0,"sequence":sequence,"epoch":epoch,"unavailable":false})).unwrap()
        };
        let mut game = Game::new();
        let now = Instant::now();
        game.flight_input.press_space(now, false);
        game.accept_characters(vec![snapshot(1, 0)]);
        game.flight_input
            .press_space(now + Duration::from_millis(100), false);
        assert_eq!(game.flight_input.request, 1);
        game.accept_characters(vec![snapshot(2, 0)]);
        assert_eq!(game.flight_input.request, 1);
        game.accept_characters(vec![snapshot(1, 1)]);
        assert_eq!(game.flight_input.request, 0);
    }
    #[test]
    fn idle_intent_carries_a_flight_request_counter() {
        let mut game = Game::new();
        game.update_input(true);
        let packet = serde_json::to_value(game.last_intent.unwrap()).unwrap();
        assert_eq!(packet["flight_request"].as_u64(), Some(0));
    }
}
