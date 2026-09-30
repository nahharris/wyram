use crate::rig::{Rig, Source};
use glam::Vec3;

fn source(prefix: &str) -> Source {
    serde_json::from_value(serde_json::json!({"id":prefix,"base_height":1.8,"capabilities":["humanoid"],"attachments":{"head":format!("{prefix}_body")},"bones":[{"name":format!("{prefix}_root"),"parent":null,"role":"root","pivot":[0,0,0],"boxes":[]},{"name":format!("{prefix}_body"),"parent":format!("{prefix}_root"),"role":"torso","pivot":[0,0,0],"boxes":[{"center":[0,0.9,0],"size":[0.5,1.8,0.3],"color":[120,150,170]}]}]})).unwrap()
}

#[test]
fn editable_sources_import_and_substitute_by_role_without_fixed_bone_names() {
    let first = Rig::import(source("first")).unwrap();
    let second = Rig::import(source("other")).unwrap();
    assert_eq!(first.role("torso"), second.role("torso"));
    let vertices = second.vertices(Vec3::new(10.0, 2.0, -3.0), 0.0, 1.4, &[]);
    assert_eq!(vertices.len(), 36);
    let min = vertices
        .iter()
        .map(|v| v.position[1])
        .fold(f32::INFINITY, f32::min);
    let max = vertices
        .iter()
        .map(|v| v.position[1])
        .fold(f32::NEG_INFINITY, f32::max);
    assert!((min - 2.0).abs() < 1e-5);
    assert!((max - 3.4).abs() < 1e-5);
}

#[test]
fn invalid_hierarchy_geometry_and_attachment_references_are_rejected() {
    let mut model = source("bad");
    model.bones[1].parent = Some("missing".into());
    assert!(Rig::import(model).is_err());
    let mut model = source("bad");
    model.bones[1].boxes[0].size[0] = 0.0;
    assert!(Rig::import(model).is_err());
    let mut model = source("bad");
    model.attachments.insert("head".into(), "missing".into());
    assert!(Rig::import(model).is_err());
}
