mod animation;
mod camera;
mod characters;
mod chunk_mesh;
mod meshing;
mod outbound;
mod replica;
mod rig;
mod telemetry;
mod world;

use std::collections::{HashMap, HashSet};
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
use crate::world::{Vertex, VoxelWorld};

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
    Hello {
        colors: HashMap<String, [u8; 3]>,
        characters: Vec<Snapshot>,
        #[serde(default)]
        models: Vec<rig::Source>,
    },
    Chunk {
        key: [i32; 3],
        revision: u64,
        data: String,
    },
    Forget {
        key: [i32; 3],
    },
}

#[derive(Clone, Copy, PartialEq, Serialize)]
struct Intent {
    forward: f32,
    right: f32,
    yaw: f32,
    pitch: f32,
    running: bool,
    jump: bool,
    sneaking: bool,
    crawling: bool,
    climbing: bool,
    rolling: bool,
    cancel_actions: bool,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientPacket {
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
    Packet(ServerPacket),
    Disconnected,
}

fn start_reader(proxy: EventLoopProxy<UserEvent>) {
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
            if let Ok(packet) = serde_json::from_slice::<ServerPacket>(&bytes) {
                let _ = proxy.send_event(UserEvent::Packet(packet));
            }
        }
    });
}

struct Graphics {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    pipeline: wgpu::RenderPipeline,
    depth: wgpu::TextureView,
    camera: wgpu::Buffer,
    camera_group: wgpu::BindGroup,
    meshes: HashMap<[i32; 3], (wgpu::Buffer, u32)>,
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
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("Wyram device"),
            required_features: wgpu::Features::empty(),
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
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
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
                targets: &[Some(config.format.into())],
            }),
            primitive: wgpu::PrimitiveState {
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::Less),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
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
            depth,
            camera,
            camera_group,
            meshes: HashMap::new(),
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

    fn render(&mut self, position: Vec3, direction: Vec3, characters: &[Vertex]) {
        let characters = &characters[..characters.len().min(rig::MAX_VERTICES)];
        if !characters.is_empty() {
            self.queue
                .write_buffer(&self.characters, 0, bytemuck::cast_slice(characters));
        }
        let aspect = self.config.width as f32 / self.config.height as f32;
        let matrix = Mat4::perspective_rh(70f32.to_radians(), aspect, 0.05, 512.0)
            * Mat4::look_to_rh(position, direction, Vec3::Y);
        self.queue.write_buffer(
            &self.camera,
            0,
            bytemuck::cast_slice(&matrix.to_cols_array()),
        );
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(frame) => frame,
            wgpu::CurrentSurfaceTexture::Suboptimal(frame) => {
                self.surface.configure(&self.device, &self.config);
                frame
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            _ => return,
        };
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
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.camera_group, &[]);
            for (buffer, count) in self.meshes.values() {
                pass.set_vertex_buffer(0, buffer.slice(..));
                pass.draw(0..*count, 0..1);
            }
            if !characters.is_empty() {
                pass.set_vertex_buffer(0, self.characters.slice(..));
                pass.draw(0..characters.len() as u32, 0..1);
            }
        }
        self.queue.submit(Some(encoder.finish()));
        self.queue.present(frame);
    }
}

struct Game {
    window: Option<Arc<Window>>,
    graphics: Option<Graphics>,
    world: VoxelWorld,
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
    pressed: HashSet<KeyCode>,
    cursor_locked: bool,
    selected: u16,
    meshing: MeshPipeline,
    telemetry: FrameTelemetry,
    decode_ms: f64,
    last_redraw: Instant,
    outbound: Option<outbound::Outbound>,
    outbound_error: Option<outbound::SendError>,
}

impl Game {
    fn new() -> Self {
        Self {
            window: None,
            graphics: None,
            world: VoxelWorld::default(),
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
            cancel_actions: false,
            cursor_locked: false,
            selected: 1,
            meshing: MeshPipeline::new(),
            telemetry: FrameTelemetry::from_env(),
            decode_ms: 0.0,
            last_redraw: Instant::now(),
            outbound: None,
            outbound_error: None,
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
        self.position = Vec3::new(x, y, z);
        self.yaw = yaw;
        self.pitch = pitch;
        self.release_input();
    }

    fn release_input(&mut self) {
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
            if self.world.block(key.0, key.1, key.2) != 0 {
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
            UserEvent::Packet(ServerPacket::Teleport {
                x,
                y,
                z,
                yaw,
                pitch,
            }) => self.apply_teleport(x, y, z, yaw, pitch),
            UserEvent::Packet(ServerPacket::Hello {
                colors,
                characters,
                models,
            }) => {
                self.world.set_palette(colors);
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
            UserEvent::Packet(ServerPacket::Forget { key }) => {
                self.world.forget(key);
                if let Some(graphics) = self.graphics.as_mut() {
                    graphics.meshes.remove(&key);
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
                            if let Some(id) = number
                                && self.world.has_block_id(id)
                            {
                                self.selected = id;
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
                    graphics.render(view.position, view.direction, &character_vertices);
                    let outbound = self
                        .outbound
                        .as_ref()
                        .map(|writer| writer.snapshot())
                        .unwrap_or_default();
                    self.telemetry.record(FrameSample {
                        frame_ms,
                        redraw_cpu_ms: start.elapsed().as_secs_f64() * 1000.0,
                        decode_ms: std::mem::take(&mut self.decode_ms),
                        worker_mesh_ms: stats.mesh_ms,
                        upload_cpu_ms: stats.upload_ms,
                        uploaded_meshes: stats.uploads,
                        uploaded_bytes: stats.upload_bytes,
                        stale_meshes: stats.stale,
                        loaded_chunks: self.world.chunk_count(),
                        dirty_chunks: self.world.dirty_count(),
                        in_flight: self.meshing.in_flight(),
                        outbound_queued: outbound.queued,
                        outbound_sent: outbound.sent,
                        outbound_coalesced_inputs: outbound.coalesced_inputs,
                        outbound_queue_max_ms: outbound.queue_max_ms,
                        outbound_write_max_ms: outbound.write_max_ms,
                        ..FrameSample::default()
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
    start_reader(event_loop.create_proxy());
    let mut game = Game::new();
    let proxy = event_loop.create_proxy();
    let (outbound, _worker) = outbound::Outbound::start(io::stdout(), move |error| {
        let _ = proxy.send_event(UserEvent::Disconnected);
        eprintln!("engine connection write failed: {error}");
    });
    game.outbound = Some(outbound);
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
}
