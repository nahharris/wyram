use super::BlendedMeshes;
use crate::world::Vertex;
use glam::{Mat4, Vec3};
use wgpu::util::DeviceExt;

#[test]
#[ignore = "requires a graphics adapter; manual offscreen rendering parity check"]
fn resident_blended_draw_matches_vertex_reference_pixels() {
    render_blended_fixture(None);
}

#[test]
#[ignore = "requires a graphics adapter; manual liquid fog check"]
fn fully_fogged_liquid_hides_background_without_grain_or_edges() {
    render_blended_fixture(Some(true));
}

#[test]
#[ignore = "requires a graphics adapter; manual fog bypass check"]
fn disabling_fog_preserves_lod_coverage_and_liquid_color() {
    render_blended_fixture(Some(false));
}

fn render_blended_fixture(fog_mode: Option<bool>) {
    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .expect("offscreen parity requires a graphics adapter");
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default()))
        .expect("offscreen parity device");
    println!("offscreen adapter: {:?}", adapter.get_info());
    let mut uniform = crate::lod_runtime::CameraUniform::disabled(Mat4::IDENTITY);
    if let Some(fog_enabled) = fog_mode {
        uniform.fog = [1.0, 1.0, 0.0, 1.0];
        uniform.grid = [-1, -1, 2, 0];
        uniform.anchor = [0, 0, 0, i32::from(!fog_enabled)];
    }
    let camera = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Parity camera"),
        contents: bytemuck::bytes_of(&uniform),
        usage: wgpu::BufferUsages::UNIFORM,
    });
    let camera_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("Parity camera layout"),
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
    let mut columns = [[1.0f32, 1.0, 0.0, 3.0]; 4];
    if fog_mode == Some(false) {
        columns[2] = [0.0; 4];
    }
    let mask = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Disabled coverage"),
        contents: bytemuck::cast_slice(&columns),
        usage: wgpu::BufferUsages::STORAGE,
    });
    let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("Parity camera group"),
        layout: &camera_layout,
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: camera.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: mask.as_entire_binding(),
            },
        ],
    });
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("Parity pipeline layout"),
        bind_group_layouts: &[Some(&camera_layout)],
        immediate_size: 0,
    });
    let shader = device.create_shader_module(wgpu::include_wgsl!("shader.wgsl"));
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("Parity pipeline"),
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
                format: wgpu::TextureFormat::Rgba8Unorm,
                blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    });
    let extent = wgpu::Extent3d {
        width: 32,
        height: 32,
        depth_or_array_layers: 1,
    };
    let images = [0, 1].map(|_| {
        device.create_texture(&wgpu::TextureDescriptor {
            label: Some("Parity image"),
            size: extent,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        })
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("Parity pixels"),
        size: 256 * 32 * 2,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let quad = |x: f32, z: f32, color| {
        [
            [x - 0.55, -0.75, z],
            [x + 0.55, -0.75, z],
            [x + 0.55, 0.75, z],
            [x + 0.55, 0.75, z],
            [x - 0.55, 0.75, z],
            [x - 0.55, -0.75, z],
        ]
        .map(|position| Vertex {
            position,
            color,
            opacity: 0.5,
        })
    };
    let mut scene = BlendedMeshes::default();
    scene.replace([1, 0, 0], &quad(0.25, 0.6, [0.0, 0.7, 1.0]));
    scene.replace([0, 0, 0], &quad(-0.25, 0.6, [1.0, 0.2, 0.0]));
    let mut previous = None;
    for (step, eye) in [Vec3::ZERO, -Vec3::X * 4.0, Vec3::X * 4.0, Vec3::ZERO]
        .into_iter()
        .enumerate()
    {
        if step == 2 {
            scene.replace([0, 0, 0], &quad(-0.25, 0.4, [0.0, 1.0, 0.1]));
        } else if step == 3 {
            scene.replace([1, 0, 0], &[]);
        }
        scene.prepare(&device, &queue, eye);
        let mut reference: Vec<_> = scene
            .chunks
            .values()
            .flat_map(|quads| quads.iter().copied())
            .collect();
        reference.sort_by(|a, b| {
            let distance = |quad: &[Vertex; 6]| {
                ((Vec3::from_array(quad[0].position) + Vec3::from_array(quad[2].position)) * 0.5)
                    .distance_squared(eye)
            };
            distance(b).total_cmp(&distance(a))
        });
        let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Reference blended vertices"),
            contents: bytemuck::cast_slice(&reference),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let mut encoder = device.create_command_encoder(&Default::default());
        for (index, image) in images.iter().enumerate() {
            let view = image.create_view(&Default::default());
            {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        depth_slice: None,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color {
                                r: if fog_mode.is_some() { 0.0 } else { 0.43 },
                                g: if fog_mode.is_some() { 0.0 } else { 0.65 },
                                b: if fog_mode.is_some() { 0.0 } else { 0.86 },
                                a: 1.0,
                            }),
                            store: wgpu::StoreOp::Store,
                        },
                    })],
                    ..Default::default()
                });
                pass.set_pipeline(&pipeline);
                pass.set_bind_group(0, &group, &[]);
                if index == 0 {
                    pass.set_vertex_buffer(0, buffer.slice(..));
                    pass.draw(0..reference.len() as u32 * 6, 0..1);
                } else {
                    scene.draw(&mut pass);
                }
            }
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo {
                    texture: image,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                wgpu::TexelCopyBufferInfo {
                    buffer: &readback,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: index as u64 * 256 * 32,
                        bytes_per_row: Some(256),
                        rows_per_image: Some(32),
                    },
                },
                extent,
            );
        }
        let submission = queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                send.send(result).expect("parity receiver alive");
            });
        device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission),
                timeout: Some(std::time::Duration::from_secs(10)),
            })
            .expect("parity GPU poll");
        receive
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("parity readback callback")
            .expect("parity readback map");
        let pixels = readback
            .slice(..)
            .get_mapped_range()
            .expect("parity mapped pixels");
        let rows = |offset: usize| {
            (0..32)
                .flat_map(|row| {
                    pixels[offset + row * 256..offset + row * 256 + 128]
                        .iter()
                        .copied()
                })
                .collect::<Vec<_>>()
        };
        let expected = rows(0);
        let actual = rows(256 * 32);
        assert!(
            actual == expected,
            "offscreen alpha pixels differ at step {step}"
        );
        if fog_mode == Some(true) {
            // All these pixels are covered by water. Full fog must obscure a dark
            // background with continuous sky color rather than transparent grain.
            for y in 8..24 {
                for x in 12..20 {
                    assert_eq!(
                        &actual[(y * 32 + x) * 4..(y * 32 + x) * 4 + 4],
                        &[110, 166, 219, 255]
                    );
                }
            }
        } else if fog_mode == Some(false) {
            let pixel = |x: usize, y: usize| &actual[(y * 32 + x) * 4..(y * 32 + x) * 4 + 4];
            assert_eq!(
                pixel(12, 12),
                &[0, 0, 0, 255],
                "unready coverage must remain hidden without fog"
            );
            assert_ne!(
                pixel(18, 12),
                &[110, 166, 219, 255],
                "fog bypass must retain liquid color"
            );
            assert_ne!(
                pixel(18, 12),
                &[0, 0, 0, 255],
                "ready coverage must remain visible without fog"
            );
        } else if let Some(previous) = previous {
            assert!(actual != previous, "fixture must exercise visible changes");
        }
        previous = Some(actual);
        drop(pixels);
        readback.unmap();
    }
}
