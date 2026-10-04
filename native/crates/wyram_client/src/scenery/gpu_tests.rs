use super::*;
use crate::world::Vertex;
use glam::Mat4;

#[test]
#[ignore = "requires a graphics adapter; offscreen scenery coverage and blending check"]
fn distant_pixels_obey_near_coverage_and_global_alpha_order() {
    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .expect("offscreen adapter");
    let (device, queue) =
        pollster::block_on(adapter.request_device(&Default::default())).expect("offscreen device");
    let camera = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Scenery test camera"),
        contents: bytemuck::cast_slice(&Mat4::IDENTITY.to_cols_array()),
        usage: wgpu::BufferUsages::UNIFORM,
    });
    let camera_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: None,
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
        label: None,
        layout: &camera_layout,
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: camera.as_entire_binding(),
        }],
    });
    let extent = wgpu::Extent3d {
        width: 32,
        height: 32,
        depth_or_array_layers: 1,
    };
    let image = device.create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: extent,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: 256 * 32,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let quad = |z, color, opacity| {
        [
            [-0.9, -0.9, z],
            [0.9, -0.9, z],
            [0.9, 0.9, z],
            [-0.9, -0.9, z],
            [0.9, 0.9, z],
            [-0.9, 0.9, z],
        ]
        .map(|position| Vertex {
            position,
            color,
            opacity,
        })
    };
    let key = TileKey::new([0, 0, 0], 1).unwrap();
    let mut scene = Scene::new(&device);
    let mut blended = BlendedMeshes::default();
    let (opaque, alpha) = scene.pipelines(
        &device,
        &camera_layout,
        wgpu::TextureFormat::Rgba8Unorm,
        false,
    );
    let render = |scene: &mut Scene, blended: &mut BlendedMeshes, eye: Vec3| {
        scene.frame(&queue, eye, 128.0);
        blended.prepare(&device, &queue, eye);
        let mut encoder = device.create_command_encoder(&Default::default());
        let view = image.create_view(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                ..Default::default()
            });
            pass.set_pipeline(&opaque);
            pass.set_bind_group(0, &camera_group, &[]);
            pass.set_bind_group(1, &scene.group, &[]);
            scene.draw(&mut pass, &Frustum::new(Mat4::IDENTITY), true);
            pass.set_pipeline(&alpha);
            blended.draw(&mut pass);
        }
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &image,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(256),
                    rows_per_image: Some(32),
                },
            },
            extent,
        );
        let submission = queue.submit([encoder.finish()]);
        let (send, receive) = std::sync::mpsc::channel();
        readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                send.send(result).unwrap();
            });
        device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission),
                timeout: Some(std::time::Duration::from_secs(10)),
            })
            .unwrap();
        receive
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap();
        let bytes = readback.slice(..).get_mapped_range().unwrap();
        let pixels = [[8, 8], [24, 8], [8, 24], [24, 24]].map(|[x, y]| {
            <[u8; 4]>::try_from(&bytes[y * 256 + x * 4..y * 256 + x * 4 + 4]).unwrap()
        });
        drop(bytes);
        readback.unmap();
        pixels
    };
    let mesh = |opacity| Mesh {
        vertices: quad(0.5, [1.0, 0.0, 0.0], opacity)
            .map(|base| ProxyVertex {
                base,
                normal: [0, 0, 127, 127],
            })
            .to_vec(),
        side: 32,
    };
    scene.upload(&device, key, mesh(1.0));
    scene.select(&HashMap::from([(key, 192)]), vec![key], &mut blended);
    let pixels = render(&mut scene, &mut blended, Vec3::ZERO);
    assert!(pixels.iter().all(|p| *p == [255, 0, 0, 255]));
    scene.near_view([0, 0, 0], 10);
    assert!(
        render(&mut scene, &mut blended, Vec3::ZERO)
            .iter()
            .all(|p| *p == [0, 0, 0, 255]),
        "unmeshed nearby columns must never show coarse proxy geometry"
    );
    scene.near_view([1000, 0, 1000], 0);
    scene.near_ready([0, 0, 0]);
    let pixels = render(&mut scene, &mut blended, Vec3::ZERO);
    assert_eq!(
        pixels[1],
        [0, 0, 0, 255],
        "ready near chunk clips its distant proxy even when its near mesh is empty"
    );
    for i in [0, 2, 3] {
        assert_eq!(
            pixels[i],
            [255, 0, 0, 255],
            "unready neighboring chunks retain coverage"
        );
    }
    scene.forget_near([0, 0, 0]);
    assert!(
        render(&mut scene, &mut blended, Vec3::ZERO)
            .iter()
            .all(|p| *p == [255, 0, 0, 255])
    );
    scene.upload(&device, key, mesh(0.5));
    scene.select(&HashMap::from([(key, 432)]), vec![key], &mut blended);
    blended.replace([0, 0, 0], &quad(0.4, [0.0, 0.0, 1.0], 0.5));
    for (eye, expected) in [
        (Vec3::ZERO, [64, 0, 128, 255]),
        (Vec3::new(0.0, 0.0, 4.0), [128, 0, 64, 255]),
    ] {
        let pixels = render(&mut scene, &mut blended, eye);
        assert!(
            pixels
                .iter()
                .all(|p| p.iter().zip(expected).all(|(&a, b)| a.abs_diff(b) <= 1)),
            "near and distant faces must share one back-to-front order: {pixels:?}"
        );
    }
    scene.select(&HashMap::new(), vec![], &mut blended);
    let pixels = render(&mut scene, &mut blended, Vec3::ZERO);
    assert!(
        pixels.iter().all(|p| p
            .iter()
            .zip([0, 0, 128, 255])
            .all(|(&a, b)| a.abs_diff(b) <= 1)),
        "releasing the distant view removes its shared alpha geometry: {pixels:?}"
    );
}
