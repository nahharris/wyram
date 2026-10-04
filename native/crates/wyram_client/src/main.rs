mod animation;
mod camera;
mod characters;
mod chunk_mesh;
mod chunk_wire;
mod flight_benchmark;
mod flight_input;
mod frame_capture;
mod frustum;
mod gpu_timer;
mod inbound;
mod meshing;
mod outbound;
mod replica;
mod rig;
mod scenery;
mod telemetry;
mod transparency;
mod world;

use std::collections::{HashMap, HashSet};
use std::io;
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

#[derive(Debug, Deserialize)]
struct Hello {
    colors: HashMap<String, [u8; 3]>,
    descriptors: HashMap<String, RenderDescriptor>,
    noncolliding: Vec<u16>,
    placeable: Vec<u16>,
    characters: Vec<Snapshot>,
    #[serde(default)]
    models: Vec<rig::Source>,
    #[serde(default)]
    scenery_planes: HashMap<String, f32>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerPacket {
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
    Hello(Box<Hello>),
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
    #[serde(skip)]
    SceneryPlan(scenery::wire::Plan),
    #[serde(skip)]
    SceneryTiles(scenery::wire::Batch),
    Forget {
        key: [i32; 3],
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
        scenery_protocol: u8,
    },
    SceneryReady {
        epoch: u64,
        delivery: u64,
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
    Packet(ServerPacket),
    Disconnected,
}

struct ReceivedPacket {
    packet: ServerPacket,
    decode_cpu_ms: f64,
    wire_bytes: usize,
    queued_at: Instant,
}

fn start_reader(
    proxy: EventLoopProxy<UserEvent>,
    credits: outbound::ScenerySender,
) -> std::sync::mpsc::Receiver<ReceivedPacket> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(32);
    std::thread::spawn(move || {
        let mut input = io::stdin().lock();
        let _ = inbound::read(&mut input, sender, &credits, || {
            proxy.send_event(UserEvent::PacketReady).is_ok()
        });
        let _ = proxy.send_event(UserEvent::Disconnected);
    });
    receiver
}

fn decode_packet(bytes: &[u8]) -> Option<ServerPacket> {
    use base64::Engine;
    if bytes.starts_with(b"WSP1") || bytes.starts_with(b"WSP2") {
        return scenery::wire::plan(bytes)
            .ok()
            .map(ServerPacket::SceneryPlan);
    }
    if bytes.starts_with(b"WST1") {
        return scenery::wire::batch(bytes)
            .ok()
            .map(ServerPacket::SceneryTiles);
    }
    if bytes.starts_with(b"WYC1") {
        return chunk_wire::decode(bytes)
            .ok()
            .map(|chunks| ServerPacket::PackedChunks { chunks });
    }
    let packet: ServerPacket = serde_json::from_slice(bytes).ok()?;
    let chunks = match packet {
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
    scenery_pipeline: wgpu::RenderPipeline,
    scenery: scenery::gpu::Scene,
    blended: transparency::BlendedMeshes,
    depth: wgpu::TextureView,
    camera: wgpu::Buffer,
    camera_group: wgpu::BindGroup,
    meshes: HashMap<[i32; 3], (wgpu::Buffer, u32)>,
    culling: bool,
    gpu_timer: Option<gpu_timer::GpuTimer>,
    characters: wgpu::Buffer,
    capture: Option<frame_capture::Capture>,
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
        let mut capture = frame_capture::Capture::from_env();
        if capture.is_some() {
            if surface
                .get_capabilities(&adapter)
                .usages
                .contains(wgpu::TextureUsages::COPY_SRC)
            {
                config.usage |= wgpu::TextureUsages::COPY_SRC;
            } else {
                eprintln!("Frame capture is unavailable on this surface");
                capture = None;
            }
        }
        surface.configure(&device, &config);
        let culling = std::env::var("WYRAM_FRUSTUM_CULLING").as_deref() != Ok("0");
        if let Some(path) = std::env::var_os("WYRAM_CLIENT_METRICS") {
            let info = adapter.get_info();
            let metadata = serde_json::json!({ "adapter": info.name, "vendor": info.vendor,
                "device": info.device, "backend": format!("{:?}", info.backend), "driver": info.driver,
                "driver_info": info.driver_info, "width": config.width, "height": config.height,
                "present_mode": format!("{:?}", config.present_mode), "timestamp_queries": timing,
                "culling": culling, "mesh_upload_limit": meshing::upload_limit(),
                "scenery_protocol": std::env::var("WYRAM_SCENERY_PROTOCOL").as_deref()!=Ok("0"),
                "scenery_protocol_version": scenery_protocol(),
                "flight_benchmark":std::env::var("WYRAM_FLIGHT_BENCHMARK").as_deref()==Ok("1"),
                "stationary_benchmark":std::env::var("WYRAM_BENCHMARK_STATIONARY").as_deref()==Ok("1"),
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
            contents: bytemuck::cast_slice(&Mat4::IDENTITY.to_cols_array()),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let camera_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Camera layout"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(64),
                },
                count: None,
            }],
        });
        let camera_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Camera"),
            layout: &camera_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: camera.as_entire_binding(),
            }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Voxel pipeline layout"),
            bind_group_layouts: &[Some(&camera_layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::include_wgsl!("shader.wgsl"));
        let make_pipeline = |blended| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("Voxel pipeline"),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_main"),
                    compilation_options: Default::default(),
                    buffers: &[Some(Vertex::layout())],
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
                    depth_compare: Some(wgpu::CompareFunction::Greater),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        };
        let pipeline = make_pipeline(false);
        let scenery = scenery::gpu::Scene::new(&device);
        let (scenery_pipeline, blended_pipeline) =
            scenery.pipelines(&device, &camera_layout, config.format, true);
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
            scenery_pipeline,
            scenery,
            blended: transparency::BlendedMeshes::default(),
            depth,
            camera,
            camera_group,
            meshes: HashMap::new(),
            culling,
            gpu_timer,
            characters,
            capture,
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
        self.scenery.near_ready(key);
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
        scenery_distance: f32,
    ) -> FrameSample {
        let mut stats = FrameSample::default();
        if let Some(capture) = &self.capture {
            capture.poll(&self.device);
        }
        if let Some(timer) = &mut self.gpu_timer {
            stats.gpu_render_ms = timer.collect(&self.device);
        }
        let blended_start = Instant::now();
        self.scenery.frame(&self.queue, position, scenery_distance);
        let blended = self.blended.prepare(&self.device, &self.queue, position);
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
        let matrix = Mat4::perspective_infinite_reverse_rh(70f32.to_radians(), aspect, 0.05)
            * Mat4::look_to_rh(position, direction, Vec3::Y);
        let frustum = frustum::Frustum::new(matrix);
        self.queue.write_buffer(
            &self.camera,
            0,
            bytemuck::cast_slice(&matrix.to_cols_array()),
        );
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
                        load: wgpu::LoadOp::Clear(0.0),
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
                pass.set_vertex_buffer(0, self.characters.slice(..));
                pass.draw(0..characters.len() as u32, 0..1);
            }
            pass.set_pipeline(&self.scenery_pipeline);
            pass.set_bind_group(1, &self.scenery.group, &[]);
            (stats.scenery_opaque_draws, stats.scenery_opaque_vertices) =
                self.scenery.draw(&mut pass, &frustum, self.culling);
            pass.set_pipeline(&self.blended_pipeline);
            self.blended.draw(&mut pass);
        }
        if let Some(timer) = &self.gpu_timer {
            timer.resolve(&mut encoder);
        }
        let capture = self
            .capture
            .as_mut()
            .and_then(|capture| capture.record(&self.device, &mut encoder, &frame.texture));
        let commands = encoder.finish();
        stats.render_encode_cpu_ms = encode_start.elapsed().as_secs_f64() * 1000.0;
        let submit_start = Instant::now();
        self.queue.submit(Some(commands));
        if let Some(capture) = capture {
            capture.submitted();
        }
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
    scenery: scenery::view::View,
    scenery_meshing: scenery::pipeline::Pipeline,
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
    benchmark: Option<flight_benchmark::FlightBenchmark>,
}

impl Game {
    fn new() -> Self {
        Self {
            window: None,
            graphics: None,
            inbound: None,
            inbound_decode_ms: 0.0,
            inbound_wire_bytes: 0,
            inbound_queue_max_ms: 0.0,
            world: VoxelWorld::default(),
            scenery: scenery::view::View::default(),
            scenery_meshing: scenery::pipeline::Pipeline::new(),
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
            benchmark: flight_benchmark::FlightBenchmark::from_env(),
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
        let mut intent = Intent {
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
        if let Some(benchmark) = &mut self.benchmark
            && let Some(replay) =
                benchmark.sample(self.replica.state.as_ref().is_some_and(|s| !s.unavailable))
        {
            intent = replay;
            self.yaw = replay.yaw;
            self.pitch = replay.pitch;
        }
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
        self.position = self
            .benchmark
            .as_ref()
            .and_then(|b| b.observer())
            .unwrap_or_else(|| self.replica.sample(&self.world));
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
                if let Some(packet) = self.inbound.as_ref().and_then(|r| r.try_recv().ok()) {
                    self.inbound_decode_ms += packet.decode_cpu_ms;
                    self.inbound_wire_bytes += packet.wire_bytes;
                    self.inbound_queue_max_ms = self
                        .inbound_queue_max_ms
                        .max(packet.queued_at.elapsed().as_secs_f64() * 1000.0);
                    self.user_event(event_loop, UserEvent::Packet(packet.packet));
                }
            }
            UserEvent::Packet(ServerPacket::PackedChunks { chunks }) => {
                let start = Instant::now();
                for chunk in chunks {
                    self.world
                        .receive_packed(chunk.key, chunk.revision, chunk.data);
                }
                self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
            }
            UserEvent::Packet(ServerPacket::SceneryPlan(plan)) => {
                self.scenery.replace(plan);
            }
            UserEvent::Packet(ServerPacket::SceneryTiles(batch)) => {
                self.scenery.accept(batch);
            }
            UserEvent::Packet(ServerPacket::Teleport {
                x,
                y,
                z,
                yaw,
                pitch,
            }) => self.apply_teleport(x, y, z, yaw, pitch),
            UserEvent::Packet(ServerPacket::Hello(hello)) => {
                let Hello {
                    colors,
                    descriptors,
                    noncolliding,
                    placeable,
                    characters,
                    models,
                    scenery_planes,
                } = *hello;
                self.world.set_palette(colors);
                self.world.set_descriptors(descriptors, noncolliding);
                self.scenery_meshing.set_water(scenery_planes, &self.world);
                self.placeable = placeable
                    .into_iter()
                    .filter(|id| self.world.has_block_id(*id))
                    .collect();
                self.selected = self.placeable.first().copied().unwrap_or(0);
                self.characters.models(models);
                self.accept_characters(characters);
            }
            UserEvent::Packet(ServerPacket::CharacterStates { characters }) => {
                self.accept_characters(characters)
            }
            UserEvent::Packet(ServerPacket::Chunk {
                key,
                revision,
                data,
            }) => {
                let start = Instant::now();
                self.world.receive_chunk(key, revision, &data);
                self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
            }
            UserEvent::Packet(ServerPacket::Chunks { chunks }) => {
                if chunks.len() <= 16 {
                    let start = Instant::now();
                    for chunk in chunks {
                        self.world
                            .receive_chunk(chunk.key, chunk.revision, &chunk.data);
                    }
                    self.decode_ms += start.elapsed().as_secs_f64() * 1000.0;
                }
            }
            UserEvent::Packet(ServerPacket::Forget { key }) => {
                self.world.forget(key);
                if let Some(graphics) = self.graphics.as_mut() {
                    graphics.meshes.remove(&key);
                    graphics.blended.replace(key, &[]);
                    graphics.scenery.forget_near(key);
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
                if self
                    .benchmark
                    .as_ref()
                    .is_some_and(|bench| bench.finished())
                {
                    event_loop.exit();
                    return;
                }
                let start = Instant::now();
                let frame_ms = (start - self.last_redraw).as_secs_f64() * 1000.0;
                self.last_redraw = start;
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
                            graphics.replace_mesh(key, vertices)
                        });
                    let selected =
                        self.scenery_meshing
                            .update(&self.scenery, &self.world, |key, mesh| {
                                graphics.scenery.upload(&graphics.device, key, mesh)
                            });
                    graphics.scenery.select(
                        self.scenery_meshing.ready(),
                        selected,
                        &mut graphics.blended,
                    );
                    let scenery_distance = self
                        .scenery
                        .plan
                        .as_ref()
                        .map_or(512.0, |plan| f32::from(plan.distance));
                    let render_stats = graphics.render(
                        view.position,
                        view.direction,
                        &character_vertices,
                        scenery_distance,
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
                        observer_position: self.position.to_array(),
                        approved_flight: self
                            .replica
                            .state
                            .as_ref()
                            .is_some_and(|s| s.mode == "fly"),
                        benchmark_elapsed_ms: self
                            .benchmark
                            .as_ref()
                            .map_or(0.0, |b| b.elapsed() * 1000.0),
                        benchmark_phase: self.benchmark.as_ref().map_or("manual", |b| b.phase()),
                        scenery_update_cpu_ms: self.scenery_meshing.stats.update_ms,
                        scenery_worker_mesh_ms: self.scenery_meshing.stats.worker_ms,
                        scenery_upload_cpu_ms: self.scenery_meshing.stats.upload_ms,
                        scenery_uploads: self.scenery_meshing.stats.uploads,
                        scenery_upload_bytes: self.scenery_meshing.stats.upload_bytes,
                        scenery_stale_meshes: self.scenery_meshing.stats.stale,
                        scenery_degraded_meshes: self.scenery_meshing.stats.degraded,
                        scenery_degraded_ready_tiles: self.scenery_meshing.degraded_ready(),
                        scenery_epoch: self.scenery.plan.as_ref().map_or(0, |p| p.epoch),
                        scenery_planned_tiles: self
                            .scenery
                            .plan
                            .as_ref()
                            .map_or(0, |p| p.nodes.len()),
                        scenery_received_tiles: self.scenery.tiles.len(),
                        scenery_ready_tiles: self.scenery_meshing.ready().len(),
                        scenery_selected_tiles: self.scenery_meshing.stats.selected,
                        scenery_in_flight: self.scenery_meshing.in_flight(),
                        scenery_failed_tiles: self.scenery_meshing.failed(),
                        scenery_mesh_reserved_bytes: self.scenery_meshing.ready().values().sum(),
                        outbound_queued: outbound.queued,
                        outbound_sent: outbound.sent,
                        outbound_coalesced_inputs: outbound.coalesced_inputs,
                        outbound_queue_max_ms: outbound.queue_max_ms,
                        outbound_write_max_ms: outbound.write_max_ms,
                        ..render_stats
                    });
                }
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

fn scenery_protocol() -> u8 {
    match std::env::var("WYRAM_SCENERY_PROTOCOL").as_deref() {
        Ok("0") => 0,
        Ok("2") => 2,
        _ => 3,
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
    let mut game = Game::new();
    let proxy = event_loop.create_proxy();
    let (outbound, _worker) = outbound::Outbound::start(io::stdout(), move |error| {
        let _ = proxy.send_event(UserEvent::Disconnected);
        eprintln!("engine connection write failed: {error}");
    });
    game.inbound = Some(start_reader(
        event_loop.create_proxy(),
        outbound.scenery_sender(),
    ));
    game.outbound = Some(outbound);
    if std::env::var("WYRAM_CHUNK_PROTOCOL").as_deref() != Ok("0") {
        game.send_packet(ClientPacket::Capabilities {
            chunk_protocol: 1,
            scenery_protocol: scenery_protocol(),
        });
    }
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
    fn hello_keeps_legacy_compatibility_and_reads_configured_surface_planes() {
        let hello = serde_json::json!({"type":"hello","colors":{},"descriptors":{},"noncolliding":[],
            "placeable":[],"characters":[]});
        let super::ServerPacket::Hello(packet) = serde_json::from_value(hello.clone()).unwrap()
        else {
            panic!("hello");
        };
        assert!(packet.scenery_planes.is_empty());
        let mut hello = hello;
        hello["scenery_planes"] = serde_json::json!({"73":-16.25});
        let super::ServerPacket::Hello(packet) = serde_json::from_value(hello).unwrap() else {
            panic!("hello");
        };
        assert_eq!(packet.scenery_planes["73"], -16.25);
    }
    #[test]
    fn background_decode_validates_scenery_packets_before_ui_delivery() {
        let mut bytes = b"WSP1".to_vec();
        for value in [3u64, 7, 5] {
            bytes.extend(value.to_be_bytes());
        }
        bytes.extend(1024u16.to_be_bytes());
        for _ in 0..2 {
            bytes.extend(67_108_864u32.to_be_bytes());
        }
        for value in [1u16, 1, 0] {
            bytes.extend(value.to_be_bytes());
        }
        for value in [-1i32, 0, 2] {
            bytes.extend(value.to_be_bytes());
        }
        bytes.extend([1, 0]);
        assert!(matches!(
            super::decode_packet(&bytes),
            Some(super::ServerPacket::SceneryPlan(_))
        ));
        bytes.push(0);
        assert!(super::decode_packet(&bytes).is_none());
        let key = wyram_core::scenery::TileKey::new([-1, 0, 2], 1).unwrap();
        let tile = wyram_core::scenery::LodTile::uniform(key, 0).encode();
        let mut bytes = b"WST1".to_vec();
        bytes.extend(3u64.to_be_bytes());
        bytes.extend(11u64.to_be_bytes());
        bytes.extend(1u16.to_be_bytes());
        bytes.extend((tile.len() as u32).to_be_bytes());
        bytes.extend(tile);
        assert!(matches!(
            super::decode_packet(&bytes),
            Some(super::ServerPacket::SceneryTiles(_))
        ));
        bytes.push(0);
        assert!(super::decode_packet(&bytes).is_none());
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
