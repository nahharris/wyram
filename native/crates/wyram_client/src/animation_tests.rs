use super::*;
use serde_json::json;
fn state() -> Snapshot {
    serde_json::from_value(json!({"id":"player","x":0.,"y":1.62,"z":0.,"feet":[0.,0.,0.],"velocity":[0.,0.,0.],"radius":0.28,"height":1.8,"eye_height":1.62,"yaw":0.,"pitch":0.,"sequence":10,"epoch":1,"unavailable":false,"grounded":true,"mode":"walk","posture":"stand"})).unwrap()
}
fn rig(prefix: &str) -> Rig {
    let roles = [
        "root",
        "hips",
        "torso",
        "head",
        "left_arm",
        "right_arm",
        "left_leg",
        "right_leg",
    ];
    let bones: Vec<_> = roles.iter().enumerate().map(|(i, role)| json!({"name":format!("{prefix}{i}"),"parent":if i==0 {None} else {Some(format!("{prefix}0"))},"role":role,"pivot":[0.,0.,0.],"boxes":if i==0 {vec![json!({"center":[0.,0.9,0.],"size":[0.5,1.8,0.3],"color":[100,100,100]})]} else {vec![]}})).collect();
    Rig::import(serde_json::from_value(json!({"id":prefix,"base_height":1.8,"bones":bones,"attachments":{},"capabilities":["humanoid"]})).unwrap()).unwrap()
}
#[test]
fn approved_states_select_clips_and_unknown_modes_fall_back() {
    let mut s = state();
    assert_eq!(Clip::select(&s), Clip::Idle);
    s.velocity = [0., 0., -5.];
    assert_eq!(Clip::select(&s), Clip::Walk);
    s.mode = "run".into();
    assert_eq!(Clip::select(&s), Clip::Run);
    s.posture = "prone".into();
    assert_eq!(Clip::select(&s), Clip::Crawl);
    s.grounded = false;
    s.velocity[1] = 3.;
    assert_eq!(Clip::select(&s), Clip::Jump);
    s.velocity[1] = -3.;
    assert_eq!(Clip::select(&s), Clip::Fall);
    s.action = Some(serde_json::from_value(json!({"kind":"wall_slide","phase":"active"})).unwrap());
    assert_eq!(Clip::select(&s), Clip::WallSlide);
    s.action = None;
    s.grounded = true;
    s.posture = "stand".into();
    s.mode = "future_mode".into();
    assert_eq!(Clip::select(&s), Clip::Idle);
    s.unavailable = true;
    assert_eq!(Clip::select(&s), Clip::Idle);
}
#[test]
fn roles_retarget_and_epochs_reset_blending_without_mutating_authority() {
    let a = rig("a");
    let b = rig("different");
    let mut s = state();
    s.velocity = [0., 0., -9.];
    s.mode = "run".into();
    let before = s.feet;
    let mut aa = Animator::default();
    let mut bb = Animator::default();
    let pa = aa.sample(&a, &s, 0.02, 0.0);
    let pb = bb.sample(&b, &s, 0.02, 0.0);
    for (x, y) in pa.iter().zip(&pb) {
        assert!(x.rotation.abs_diff_eq(y.rotation, 1e-6));
    }
    assert_eq!(s.feet, before);
    let phase = aa.phase;
    aa.sample(&a, &s, 10.0, 10.0);
    assert_eq!(aa.phase, phase);
    s.epoch += 1;
    s.velocity = [0., 0., 0.];
    s.pitch = 0.;
    let reset = aa.sample(&a, &s, 0.02, 0.0);
    assert!(
        reset
            .iter()
            .all(|p| p.rotation.abs_diff_eq(Quat::IDENTITY, 1e-6))
    );
    let vertices = a.vertices(Vec3::new(2., 3., 4.), 0., 0.6, &pb);
    let low = vertices
        .iter()
        .map(|v| v.position[1])
        .fold(f32::INFINITY, f32::min);
    let high = vertices
        .iter()
        .map(|v| v.position[1])
        .fold(f32::NEG_INFINITY, f32::max);
    assert!((low - 3.).abs() < 1e-5 && (high - 3.6).abs() < 1e-5);
}
#[test]
fn rolls_use_authoritative_progress_and_direction_and_interruption_blends_out() {
    let r = rig("r");
    let mut s = state();
    let mut poses = Vec::new();
    for dir in ["forward", "backward", "left", "right"] {
        s.action=Some(serde_json::from_value(json!({"kind":"roll","phase":"active","elapsed":0.1,"duration":0.4,"local_direction":dir})).unwrap());
        let mut a = Animator::default();
        poses.push(a.sample(&r, &s, 0.02, 0.0)[r.role("root").unwrap()].rotation);
    }
    for i in 0..4 {
        for j in i + 1..4 {
            assert!(!poses[i].abs_diff_eq(poses[j], 1e-4));
        }
    }
    let mut a = Animator::default();
    a.sample(&r, &s, 0.02, 0.0);
    s.action = None;
    let output = a.sample(&r, &s, 0.05, 0.0);
    assert!(output.iter().all(|p| p.rotation.is_finite()));
    let legacy=Rig::import(serde_json::from_value(json!({"id":"legacy","base_height":1.,"bones":[{"name":"one","parent":null,"role":"root","pivot":[0.,0.,0.],"boxes":[{"center":[0.,0.5,0.],"size":[0.5,1.,0.5],"color":[100,100,100]}]}],"attachments":{},"capabilities":[]})).unwrap()).unwrap();
    assert!(
        a.sample(&legacy, &s, 0.02, 0.0)
            .iter()
            .all(|p| p.rotation == Quat::IDENTITY)
    );
}

#[test]
fn landing_recovers_and_traversal_clips_have_finite_role_poses() {
    let r = rig("all");
    let mut s = state();
    let mut a = Animator::default();
    s.grounded = false;
    s.velocity = [0., -4., 0.];
    a.sample(&r, &s, 0.02, 0.);
    s.grounded = true;
    s.velocity = [0., 0., 0.];
    a.sample(&r, &s, 0.02, 0.);
    assert_eq!(a.clip, Clip::Land);
    for _ in 0..10 {
        a.sample(&r, &s, 0.02, 0.);
    }
    assert_eq!(a.clip, Clip::Idle);
    for kind in ["climb", "slide", "wall_slide"] {
        s.action = Some(serde_json::from_value(json!({"kind":kind,"phase":"active"})).unwrap());
        let poses = a.sample(&r, &s, 0.02, 0.);
        assert!(
            poses
                .iter()
                .all(|p| p.rotation.is_finite() && p.offset == Vec3::ZERO)
        );
    }
}

#[test]
fn approved_takeoff_and_landing_transitions_have_a_short_anticipation_pose() {
    let mut s = state();
    s.velocity = [0., 0., -5.];
    s.transition = "jump_start".into();
    assert_eq!(Clip::select(&s), Clip::Land);
    s.transition = "landing".into();
    assert_eq!(Clip::select(&s), Clip::Land);
    s.transition = "move".into();
    assert_eq!(Clip::select(&s), Clip::Walk);
}
