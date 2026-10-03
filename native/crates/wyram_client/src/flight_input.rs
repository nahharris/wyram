//! Input gestures carry a monotonic request counter through coalesced intent packets.
use std::time::{Duration, Instant};
#[derive(Default)]
pub struct FlightInput {
    last_space: Option<Instant>,
    pub request: u64,
}
impl FlightInput {
    pub fn press_space(&mut self, now: Instant, repeated: bool) {
        if repeated {
            return;
        }
        if self
            .last_space
            .is_some_and(|last| now.duration_since(last) <= Duration::from_millis(300))
        {
            self.request = self.request.saturating_add(1);
            self.last_space = None;
        } else {
            self.last_space = Some(now);
        }
    }
    pub fn release_controls(&mut self) {
        self.last_space = None;
    }
    pub fn reset_epoch(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_double_press_requests_flight_but_holds_and_slow_presses_do_not() {
        let now = Instant::now();
        let mut input = FlightInput::default();
        input.press_space(now, false);
        input.press_space(now + Duration::from_millis(100), true);
        assert_eq!(input.request, 0);
        input.press_space(now + Duration::from_millis(200), false);
        assert_eq!(input.request, 1);
        input.press_space(now + Duration::from_millis(250), false);
        assert_eq!(input.request, 1);
        input.press_space(now + Duration::from_millis(600), false);
        assert_eq!(input.request, 1);
        input.press_space(now + Duration::from_millis(700), false);
        assert_eq!(input.request, 2);
    }
    #[test]
    fn focus_release_cancels_half_gestures_but_preserves_requests_and_epochs_reset_them() {
        let now = Instant::now();
        let mut input = FlightInput::default();
        input.press_space(now, false);
        input.release_controls();
        input.press_space(now + Duration::from_millis(100), false);
        assert_eq!(input.request, 0);
        input.press_space(now + Duration::from_millis(200), false);
        input.release_controls();
        assert_eq!(input.request, 1);
        input.reset_epoch();
        assert_eq!(input.request, 0);
        input.press_space(now + Duration::from_millis(250), false);
        assert_eq!(input.request, 0);
    }
}
