//! Command-line configuration of one benchmark run.

use crate::work::WorkParams;
use serde::Serialize;
use std::{path::PathBuf, time::Duration};

/// The scenarios of stage 9 (issue #13, design v2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Scenario {
    /// One window, one request.
    S1,
    /// Two windows, concurrent requests for one key.
    S2,
    /// Two windows, concurrent requests for distinct keys.
    S3,
    /// Two windows, one key, consecutive rounds within one TTL.
    S4,
}

impl Scenario {
    fn parse(value: &str) -> Result<Self, String> {
        match value.to_ascii_uppercase().as_str() {
            "S1" => Ok(Self::S1),
            "S2" => Ok(Self::S2),
            "S3" => Ok(Self::S3),
            "S4" => Ok(Self::S4),
            other => Err(format!(
                "unknown scenario {other:?}; expected S1, S2, S3 or S4"
            )),
        }
    }

    /// TTL of the runtime build. S1–S3 store nothing, so only coalescing can
    /// apply; S4 keeps a result for longer than any run.
    pub const fn ttl(self) -> Option<Duration> {
        match self {
            Self::S4 => Some(Duration::from_secs(3600)),
            _ => None,
        }
    }
}

/// Which variant this executable is; fixed at compile time.
pub const BUILD: &str = if cfg!(feature = "runtime") {
    "runtime"
} else {
    "plain"
};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BenchConfig {
    pub build: &'static str,
    pub scenario: Scenario,
    /// `none` for plain, `noStore` or `ttl:<ms>` for runtime.
    pub policy: String,
    pub work: WorkParams,
    pub requests_per_window: u32,
    pub duration_seconds: u32,
    pub round_interval_ms: u32,
    pub idle_before_seconds: u32,
    pub idle_after_seconds: u32,
    /// Set only for an automated run: the app runs the scenario, writes the
    /// report here and exits.
    #[serde(skip)]
    pub report_path: Option<PathBuf>,
    pub automated: bool,
}

impl BenchConfig {
    /// Parses `--name value` pairs. Unknown names are errors, so a typo cannot
    /// silently run the wrong configuration.
    pub fn from_args<I: IntoIterator<Item = String>>(args: I) -> Result<Self, String> {
        let mut scenario = Scenario::S2;
        let mut work = WorkParams::default();
        let mut requests_per_window = 10;
        let mut duration_seconds = 60;
        let mut round_interval_ms = 500;
        let mut idle_before_seconds = 10;
        let mut idle_after_seconds = 10;
        let mut report_path = None;

        let mut args = args.into_iter();
        while let Some(name) = args.next() {
            let value = args.next().ok_or_else(|| format!("{name} needs a value"))?;
            match name.as_str() {
                "--scenario" => scenario = Scenario::parse(&value)?,
                "--report" => report_path = Some(PathBuf::from(value)),
                "--duration" => duration_seconds = number(&name, &value, 1, 600)?,
                "--requests-per-window" => requests_per_window = number(&name, &value, 1, 50)?,
                "--buffer-mb" => work.buffer_mb = number(&name, &value, 1, 8)?,
                "--iterations" => work.iterations = number(&name, &value, 1, 100_000)?,
                "--round-interval-ms" => round_interval_ms = number(&name, &value, 0, 60_000)?,
                "--idle-before" => idle_before_seconds = number(&name, &value, 0, 600)?,
                "--idle-after" => idle_after_seconds = number(&name, &value, 0, 600)?,
                other => return Err(format!("unknown option {other}")),
            }
        }
        if scenario == Scenario::S1 {
            requests_per_window = 1;
        }

        let policy = if BUILD == "plain" {
            "none".to_owned()
        } else {
            match scenario.ttl() {
                Some(ttl) => format!("ttl:{}", ttl.as_millis()),
                None => "noStore".to_owned(),
            }
        };

        Ok(Self {
            build: BUILD,
            scenario,
            policy,
            work,
            requests_per_window,
            duration_seconds,
            round_interval_ms,
            idle_before_seconds,
            idle_after_seconds,
            automated: report_path.is_some(),
            report_path,
        })
    }
}

fn number(name: &str, value: &str, min: u32, max: u32) -> Result<u32, String> {
    match value.parse::<u32>() {
        Ok(number) if (min..=max).contains(&number) => Ok(number),
        _ => Err(format!(
            "{name} must be an integer from {min} to {max}, got {value:?}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::{BUILD, BenchConfig, Scenario};

    fn parse(args: &[&str]) -> Result<BenchConfig, String> {
        BenchConfig::from_args(args.iter().map(|arg| (*arg).to_owned()))
    }

    #[test]
    fn defaults_are_an_interactive_s2_run() {
        let config = parse(&[]).unwrap();
        assert_eq!(config.scenario, Scenario::S2);
        assert_eq!(config.requests_per_window, 10);
        assert_eq!(config.work.buffer_mb, 4);
        assert!(!config.automated);
        assert_eq!(config.build, BUILD);
    }

    #[test]
    fn a_report_path_makes_the_run_automated() {
        let config = parse(&[
            "--scenario",
            "s4",
            "--report",
            "out.json",
            "--duration",
            "5",
        ])
        .unwrap();
        assert_eq!(config.scenario, Scenario::S4);
        assert!(config.automated);
        assert_eq!(config.duration_seconds, 5);
        let expected = if BUILD == "plain" {
            "none"
        } else {
            "ttl:3600000"
        };
        assert_eq!(config.policy, expected);
    }

    #[test]
    fn s1_always_sends_one_request() {
        assert_eq!(
            parse(&["--scenario", "S1", "--requests-per-window", "7"])
                .unwrap()
                .requests_per_window,
            1
        );
    }

    #[test]
    fn rejects_unknown_options_and_unsafe_sizes() {
        assert!(parse(&["--scenario", "S5"]).is_err());
        assert!(parse(&["--buffer-mb", "64"]).is_err());
        assert!(parse(&["--requests-per-window", "100"]).is_err());
        assert!(parse(&["--bogus", "1"]).is_err());
        assert!(parse(&["--duration"]).is_err());
    }
}
