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
    for dir in ["forward", "back", "left", "right"] {
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
                .all(|p| p.rotation.is_finite() && p.offset.is_finite())
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
    s.posture = "prone".into();
    assert_eq!(Clip::select(&s), Clip::Crawl);
    s.posture = "stand".into();
    s.transition = "move".into();
    assert_eq!(Clip::select(&s), Clip::Walk);
}

#[test]
fn rolls_tip_toward_the_approved_direction_and_climbing_reaches_forward() {
    let r = rig("direction");
    let mut s = state();
    for (direction, expected) in [
        ("forward", Vec3::NEG_Z),
        ("back", Vec3::Z),
        ("left", Vec3::NEG_X),
        ("right", Vec3::X),
    ] {
        s.action=Some(serde_json::from_value(json!({"kind":"roll","phase":"active","elapsed":0.1,"duration":0.4,"local_direction":direction})).unwrap());
        let p = Animator::default().sample(&r, &s, 0.02, 0.);
        assert!(
            (p[r.role("root").unwrap()].rotation * Vec3::Y).abs_diff_eq(expected, 1e-5),
            "{direction}"
        );
    }
    s.action = Some(serde_json::from_value(json!({"kind":"climb","phase":"rise"})).unwrap());
    let p = Animator::default().sample(&r, &s, 0.02, 0.);
    for role in ["left_arm", "right_arm"] {
        let hand = p[r.role(role).unwrap()].rotation * Vec3::NEG_Y;
        assert!(
            hand.z < 0. && hand.y > 0.,
            "hands must reach forward and up"
        );
    }
}

#[test]
fn gait_phase_is_continuous_and_cadence_matches_distance_at_different_frame_rates() {
    let r = rig("cadence");
    for fps in [50, 100, 200] {
        let mut s = state();
        s.sequence = 0;
        s.velocity = [0., 0., -5.];
        let mut a = Animator::default();
        a.sample(&r, &s, 0., 0.);
        for frame in 1..=fps {
            let time = frame as f32 / fps as f32;
            s.sequence = (time / 0.02).floor() as u64;
            a.sample(&r, &s, 1. / fps as f32, time - s.sequence as f32 * 0.02);
        }
        let stride = 4. * (r.source.base_height * 0.2) * 0.65_f32.sin();
        let expected = (5. / stride * TAU).rem_euclid(TAU);
        assert!(
            (a.phase - expected).abs() < 0.001,
            "fps {fps}: {} expected {expected}",
            a.phase
        );
        let phase = a.phase;
        s.velocity = [0., 0., -9.];
        s.mode = "run".into();
        a.sample(&r, &s, 0., 0.);
        assert_eq!(
            a.phase, phase,
            "changing speed without elapsed time cannot change phase"
        );
        a.sample(&r, &s, 1., 1.);
        assert_eq!(a.phase, phase, "stale snapshots must freeze gait");
    }
}

#[test]
fn stance_foot_matches_distance_and_fast_steps_are_not_filtered_away() {
    let length = 0.25;
    let amplitude = 0.65_f32;
    let stride = 4. * length * amplitude.sin();
    let phase0 = 0.2 * PI;
    let phase1 = 0.4 * PI;
    let foot_z = |phase| -length * leg_angle(phase, amplitude, 0.).sin();
    assert!((foot_z(phase1) - foot_z(phase0) - stride * (phase1 - phase0) / TAU).abs() < 1e-6);
    let r = rig("steps");
    let mut s = state();
    s.velocity = [0., 0., -9.];
    s.mode = "run".into();
    let mut a = Animator::default();
    a.sample(&r, &s, 0.02, 0.);
    s.sequence += 1;
    let p = a.sample(&r, &s, 0.02, 0.);
    let target = pose(&r, &s, Clip::Run, a.phase);
    assert!(
        p[r.role("left_leg").unwrap()]
            .rotation
            .abs_diff_eq(target[r.role("left_leg").unwrap()].rotation, 1e-6)
    );
}

#[test]
fn dwarf_low_postures_keep_rigid_parts_within_their_clearance_heights() {
    let part = |center: [f32; 3], size: [f32; 3]| json!({"center":center,"size":size,"color":[100,100,100]});
    let bone = |name: &str,
                parent: Option<&str>,
                role: &str,
                pivot: [f32; 3],
                boxes: Vec<serde_json::Value>| json!({"name":name,"parent":parent,"role":role,"pivot":pivot,"boxes":boxes});
    let bones = vec![
        bone("root", None, "root", [0.; 3], vec![]),
        bone(
            "hips",
            Some("root"),
            "hips",
            [0., 0.25, 0.],
            vec![part([0., 0.03125, 0.], [0.4375, 0.0625, 0.3125])],
        ),
        bone(
            "body",
            Some("hips"),
            "torso",
            [0.; 3],
            vec![part([0., 0.1875, 0.], [0.4375, 0.375, 0.3125])],
        ),
        bone(
            "head",
            Some("body"),
            "head",
            [0., 0.375, 0.],
            vec![part([0., 0.375, 0.], [0.75, 0.75, 0.625])],
        ),
        bone(
            "arm_l",
            Some("body"),
            "left_arm",
            [0.3, 0.375, 0.],
            vec![part([0., -0.1875, 0.], [0.15, 0.375, 0.225])],
        ),
        bone(
            "arm_r",
            Some("body"),
            "right_arm",
            [-0.3, 0.375, 0.],
            vec![part([0., -0.1875, 0.], [0.15, 0.375, 0.225])],
        ),
        bone(
            "leg_l",
            Some("hips"),
            "left_leg",
            [0.125, 0., 0.],
            vec![part([0., -0.125, -0.025], [0.2, 0.25, 0.3])],
        ),
        bone(
            "leg_r",
            Some("hips"),
            "right_leg",
            [-0.125, 0., 0.],
            vec![part([0., -0.125, -0.025], [0.2, 0.25, 0.3])],
        ),
    ];
    let r=Rig::import(serde_json::from_value(json!({"id":"dwarf","base_height":1.375,"bones":bones,"attachments":{},"capabilities":["humanoid"]})).unwrap()).unwrap();
    assert!((r.leg_length() - 0.25).abs() < 1e-6);
    let rest = r.vertices(Vec3::ZERO, 0., 1.375, &[]);
    for (posture, height, speed) in [("crouch", 1.25, 2.), ("prone", 0.875, 0.65)] {
        let mut s = state();
        s.posture = posture.into();
        s.height = height;
        s.standing_height = Some(1.375);
        s.velocity = [0., 0., -speed];
        let mut a = Animator::default();
        for frame in 0..100 {
            s.sequence = frame;
            s.pitch = if frame < 50 { -0.8 } else { 0.8 };
            let p = a.sample(&r, &s, 0.02, 0.);
            let vertices = r.vertices(Vec3::ZERO, 0., s.standing_height.unwrap(), &p);
            let high = vertices.iter().map(|v| v.position[1]).fold(0_f32, f32::max);
            assert!(high <= height + 1e-5, "{posture}: {high} exceeds {height}");
            for (original, posed) in rest
                .as_chunks::<36>()
                .0
                .iter()
                .zip(vertices.as_chunks::<36>().0)
            {
                let distance = |v: &[crate::world::Vertex]| {
                    Vec3::from_array(v[0].position).distance(Vec3::from_array(v[2].position))
                };
                assert!((distance(original) - distance(posed)).abs() < 1e-5);
            }
        }
    }
}
