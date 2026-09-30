mod meshing;
mod telemetry;
mod world;

use std::collections::{HashMap, HashSet};
use std::io::{self, Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use glam::{Mat4, Vec3};
use serde::{Deserialize, Serialize};
use wgpu::util::DeviceExt;
use winit::application::ApplicationHandler;
use winit::event::{DeviceEvent, ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{CursorGrabMode, Window, WindowId};

use crate::meshing::MeshPipeline;
use crate::telemetry::{FrameSample, FrameTelemetry};
use crate::world::{Vertex, VoxelWorld};

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerPacket {
    Teleport {
        x: f32,
        y: f32,
        z: f32,
        yaw: f32,
        pitch: f32,
    },
    Hello {
        colors: HashMap<String, [u8; 3]>,
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

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientPacket {
    Player {
        x: f32,
        y: f32,
        z: f32,
        yaw: f32,
        pitch: f32,
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

fn send_packet(packet: ClientPacket) {
    if let Ok(bytes) = serde_json::to_vec(&packet)
        && let Ok(length) = u32::try_from(bytes.len())
    {
        let mut out = io::stdout().lock();
        let _ = out.write_all(&length.to_be_bytes());
        let _ = out.write_all(&bytes);
        let _ = out.flush();
    }
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

    fn render(&mut self, position: Vec3, direction: Vec3) {
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
    vertical_speed: f32,
    grounded: bool,
    pressed: HashSet<KeyCode>,
    cursor_locked: bool,
    selected: u16,
    last_frame: Instant,
    last_view: (i32, i32),
    last_report: Instant,
    meshing: MeshPipeline,
    telemetry: FrameTelemetry,
    decode_ms: f64,
    last_redraw: Instant,
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
            vertical_speed: 0.0,
            grounded: false,
            pressed: HashSet::new(),
            cursor_locked: false,
            selected: 1,
            last_frame: Instant::now(),
            last_view: (i32::MAX, i32::MAX),
            last_report: Instant::now() - Duration::from_secs(1),
            meshing: MeshPipeline::new(),
            telemetry: FrameTelemetry::from_env(),
            decode_ms: 0.0,
            last_redraw: Instant::now(),
        }
    }

    fn direction(&self) -> Vec3 {
        Vec3::new(
            self.yaw.sin() * self.pitch.cos(),
            self.pitch.sin(),
            -self.yaw.cos() * self.pitch.cos(),
        )
    }

    fn apply_teleport(&mut self, x: f32, y: f32, z: f32, yaw: f32, pitch: f32) {
        self.position = Vec3::new(x, y, z);
        self.yaw = yaw;
        self.pitch = pitch;
        self.vertical_speed = 0.0;
        self.grounded = false;
        self.pressed.clear();
        self.last_view = (i32::MAX, i32::MAX);
        self.last_report = Instant::now() - Duration::from_secs(1);
    }

    fn step(&mut self) {
        let now = Instant::now();
        let dt = (now - self.last_frame).as_secs_f32().min(0.05);
        self.last_frame = now;
        let forward = Vec3::new(self.yaw.sin(), 0.0, -self.yaw.cos());
        let right = Vec3::new(-forward.z, 0.0, forward.x);
        let mut wish = Vec3::ZERO;
        if self.pressed.contains(&KeyCode::KeyW) {
            wish += forward;
        }
        if self.pressed.contains(&KeyCode::KeyS) {
            wish -= forward;
        }
        if self.pressed.contains(&KeyCode::KeyD) {
            wish += right;
        }
        if self.pressed.contains(&KeyCode::KeyA) {
            wish -= right;
        }
        let speed = if self.pressed.contains(&KeyCode::ControlLeft) {
            9.0
        } else {
            5.0
        };
        let horizontal = wish.normalize_or_zero() * speed * dt;
        let next_x = self.position + Vec3::new(horizontal.x, 0.0, 0.0);
        if !self.world.collides(next_x) {
            self.position.x = next_x.x;
        }
        let next_z = self.position + Vec3::new(0.0, 0.0, horizontal.z);
        if !self.world.collides(next_z) {
            self.position.z = next_z.z;
        }
        if self.grounded && self.pressed.contains(&KeyCode::Space) {
            self.vertical_speed = 7.0;
            self.grounded = false;
        }
        self.vertical_speed = (self.vertical_speed - 20.0 * dt).max(-25.0);
        let next_y = self.position + Vec3::new(0.0, self.vertical_speed * dt, 0.0);
        if self.world.collides(next_y) {
            if self.vertical_speed < 0.0 {
                self.grounded = true;
            }
            self.vertical_speed = 0.0;
        } else {
            self.position.y = next_y.y;
            self.grounded = false;
        }
        let center = (
            (self.position.x.floor() as i32).div_euclid(16),
            (self.position.z.floor() as i32).div_euclid(16),
        );
        if center != self.last_view || self.last_report.elapsed() >= Duration::from_millis(200) {
            send_packet(ClientPacket::Player {
                x: self.position.x,
                y: self.position.y,
                z: self.position.z,
                yaw: self.yaw,
                pitch: self.pitch,
            });
            self.last_view = center;
            self.last_report = now;
        }
    }

    fn edit(&self, place: bool) {
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
                send_packet(ClientPacket::Edit {
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
            UserEvent::Packet(ServerPacket::Hello { colors }) => self.world.set_palette(colors),
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
            WindowEvent::Resized(size) => {
                if let Some(graphics) = self.graphics.as_mut() {
                    graphics.resize(size.width, size.height);
                }
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if let PhysicalKey::Code(code) = event.physical_key {
                    match event.state {
                        ElementState::Pressed => {
                            self.pressed.insert(code);
                            if code == KeyCode::Escape {
                                self.cursor_locked = false;
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
                if let Some(graphics) = self.graphics.as_mut() {
                    let center = [self.position.x, self.position.y, self.position.z]
                        .map(|v| (v.floor() as i32).div_euclid(16));
                    let stats = self
                        .meshing
                        .update(&mut self.world, center, |key, vertices| {
                            graphics.replace_mesh(key, vertices)
                        });
                    graphics.render(self.position, direction);
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
            self.yaw += delta.0 as f32 * 0.002;
            self.pitch = (self.pitch - delta.1 as f32 * 0.002).clamp(-1.55, 1.55);
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(window) = &self.window {
            window.request_redraw();
        }
    }
}

fn main() {
    let event_loop = EventLoop::<UserEvent>::with_user_event()
        .build()
        .expect("event loop creation failed");
    start_reader(event_loop.create_proxy());
    let mut game = Game::new();
    event_loop
        .run_app(&mut game)
        .expect("game event loop failed");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn teleport_resets_movement_and_repositions_player() {
        let mut game = Game::new();
        game.vertical_speed = -12.0;
        game.grounded = true;
        game.apply_teleport(32.5, 90.0, -7.5, 1.0, -0.25);
        assert_eq!(game.position, Vec3::new(32.5, 90.0, -7.5));
        assert_eq!((game.yaw, game.pitch), (1.0, -0.25));
        assert_eq!(game.vertical_speed, 0.0);
        assert!(!game.grounded);
        assert_eq!(game.last_view, (i32::MAX, i32::MAX));
    }
}
