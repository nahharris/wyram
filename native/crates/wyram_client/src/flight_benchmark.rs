use crate::Intent;
use std::time::{Duration, Instant};

/// Opt-in repeatable input replay. Elixir still approves flight and motion.
pub struct FlightBenchmark {
    created: Instant,
    started: Option<Instant>,
    stationary: bool,
    stationary_seconds: u64,
}
impl FlightBenchmark {
    pub fn from_env() -> Option<Self> {
        (std::env::var("WYRAM_FLIGHT_BENCHMARK").as_deref() == Ok("1")).then(|| Self {
            created: Instant::now(),
            started: None,
            stationary: std::env::var("WYRAM_BENCHMARK_STATIONARY").as_deref() == Ok("1"),
            stationary_seconds: std::env::var("WYRAM_BENCHMARK_STATIONARY_SECONDS")
                .ok()
                .and_then(|value| value.parse().ok())
                .filter(|seconds| (35..=120).contains(seconds))
                .unwrap_or(35),
        })
    }
    pub fn sample(&mut self, available: bool) -> Option<Intent> {
        if !available && self.started.is_none() {
            return None;
        }
        let start = self.started.get_or_insert_with(Instant::now);
        Some(if self.stationary {
            intent(0.0)
        } else {
            intent(start.elapsed().as_secs_f32())
        })
    }
    pub fn elapsed(&self) -> f64 {
        self.started
            .map_or(0.0, |start| start.elapsed().as_secs_f64())
    }
    /// Stationary renderer measurements use an exact presentation viewpoint.
    /// Gameplay and chunk streaming still follow the approved player state.
    pub fn observer(&self) -> Option<glam::Vec3> {
        self.stationary
            .then_some(glam::Vec3::new(672.5, 300.0, 672.5))
    }
    pub fn phase(&self) -> &'static str {
        if self.started.is_none() {
            "waiting"
        } else if self.stationary {
            "stationary"
        } else {
            phase(self.elapsed() as f32)
        }
    }
    pub fn finished(&self) -> bool {
        self.elapsed()
            >= if self.stationary {
                self.stationary_seconds as f64
            } else {
                95.0
            }
            || self.created.elapsed() >= Duration::from_secs(135)
    }
}

fn phase(seconds: f32) -> &'static str {
    if seconds < 5.0 {
        "settle"
    } else if seconds < 25.0 {
        "rise"
    } else if seconds < 55.0 {
        "outbound"
    } else if seconds < 85.0 {
        "return"
    } else {
        "settled"
    }
}
fn intent(seconds: f32) -> Intent {
    Intent {
        forward: if (25.0..55.0).contains(&seconds) {
            1.0
        } else if (55.0..85.0).contains(&seconds) {
            -1.0
        } else {
            0.0
        },
        right: 0.0,
        yaw: 0.0,
        pitch: -0.3,
        running: true,
        jump: (5.0..25.0).contains(&seconds),
        flight_request: 1,
        sneaking: false,
        crawling: false,
        climbing: false,
        rolling: false,
        cancel_actions: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn longer_stationary_captures_keep_a_finite_exit_deadline() {
        let mut benchmark = FlightBenchmark {
            created: Instant::now(),
            started: Some(Instant::now() - Duration::from_secs(74)),
            stationary: true,
            stationary_seconds: 75,
        };
        assert!(!benchmark.finished());
        benchmark.started = Some(Instant::now() - Duration::from_secs(75));
        assert!(benchmark.finished());
        benchmark.started = None;
        benchmark.created = Instant::now() - Duration::from_secs(135);
        assert!(
            benchmark.finished(),
            "an unavailable player cannot leave a test game running"
        );
    }

    #[test]
    fn replay_requests_flight_once_and_returns_over_the_same_route() {
        for seconds in [0.0, 5.0, 25.0, 55.0, 85.0] {
            let input = intent(seconds);
            assert_eq!(input.flight_request, 1);
            assert!(!input.cancel_actions && !input.rolling && !input.climbing);
        }
        assert!(intent(5.0).jump);
        assert!(!intent(25.0).jump);
        assert_eq!(intent(25.0).forward, -intent(55.0).forward);
        assert_eq!(intent(85.0).forward, 0.0);
        assert_eq!(phase(25.0), "outbound");
        assert_eq!(phase(55.0), "return");
    }
}
