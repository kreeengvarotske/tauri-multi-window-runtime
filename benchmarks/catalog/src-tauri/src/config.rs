//! Command-line configuration of one run of scenario M.

use serde::Serialize;
use std::path::PathBuf;

#[cfg(all(feature = "shared", feature = "framework"))]
compile_error!("features `shared` (arm B) and `framework` (arm C) are exclusive");

/// Which arm this executable is; fixed at compile time.
pub const ARM: &str = if cfg!(feature = "framework") {
    "C"
} else if cfg!(feature = "shared") {
    "B"
} else {
    "A"
};

/// Human-readable arm name.
pub const ARM_NAME: &str = if cfg!(feature = "framework") {
    "shared-framework"
} else if cfg!(feature = "shared") {
    "shared-manual"
} else {
    "per-window"
};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogConfig {
    pub scenario: &'static str,
    pub arm: &'static str,
    pub arm_name: &'static str,
    /// Nominal size of the Rust representation, MiB (`D`).
    pub data_mib: u32,
    pub seed: u64,
    /// Windows, `main` included (`N`).
    pub windows: u32,
    pub step_interval_ms: u32,
    pub idle_before_seconds: u32,
    pub warmup_seconds: u32,
    pub load_seconds: u32,
    pub idle_after_seconds: u32,
    /// Set by the app at startup from the generated catalog.
    pub records: u32,
    pub rust_data_bytes: u64,
    #[serde(skip)]
    pub report_path: Option<PathBuf>,
    pub automated: bool,
}

impl CatalogConfig {
    /// Parses `--name value` pairs. Unknown names are errors.
    pub fn from_args<I: IntoIterator<Item = String>>(args: I) -> Result<Self, String> {
        let mut config = Self {
            scenario: "M",
            arm: ARM,
            arm_name: ARM_NAME,
            data_mib: 16,
            seed: 1,
            windows: 2,
            step_interval_ms: 500,
            idle_before_seconds: 20,
            warmup_seconds: 30,
            load_seconds: 120,
            idle_after_seconds: 30,
            records: 0,
            rust_data_bytes: 0,
            report_path: None,
            automated: false,
        };
        let mut args = args.into_iter();
        while let Some(name) = args.next() {
            let value = args.next().ok_or_else(|| format!("{name} needs a value"))?;
            match name.as_str() {
                "--data-mib" => config.data_mib = number(&name, &value, 0, 256)?,
                "--seed" => config.seed = u64::from(number(&name, &value, 1, u32::MAX)?),
                "--windows" => config.windows = number(&name, &value, 1, 8)?,
                "--step-interval-ms" => {
                    config.step_interval_ms = number(&name, &value, 100, 10_000)?
                }
                "--idle-before" => config.idle_before_seconds = number(&name, &value, 0, 600)?,
                "--warmup" => config.warmup_seconds = number(&name, &value, 0, 600)?,
                "--duration" => config.load_seconds = number(&name, &value, 1, 600)?,
                "--idle-after" => config.idle_after_seconds = number(&name, &value, 0, 600)?,
                "--report" => config.report_path = Some(PathBuf::from(value)),
                other => return Err(format!("unknown option {other}")),
            }
        }
        config.automated = config.report_path.is_some();
        Ok(config)
    }

    pub fn target_bytes(&self) -> usize {
        self.data_mib as usize * (1 << 20)
    }

    /// Labels of every window, `main` first.
    pub fn labels(&self) -> Vec<String> {
        std::iter::once("main".to_owned())
            .chain((1..self.windows).map(|i| format!("w{i}")))
            .collect()
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
    use super::*;

    fn parse(args: &[&str]) -> Result<CatalogConfig, String> {
        CatalogConfig::from_args(args.iter().map(|a| (*a).to_owned()))
    }

    #[test]
    fn defaults_follow_the_protocol() {
        let config = parse(&[]).unwrap();
        assert_eq!((config.data_mib, config.windows), (16, 2));
        assert_eq!(
            (
                config.idle_before_seconds,
                config.warmup_seconds,
                config.load_seconds,
                config.idle_after_seconds,
                config.step_interval_ms
            ),
            (20, 30, 120, 30, 500)
        );
        assert!(!config.automated);
        assert_eq!(config.arm, ARM);
        assert_eq!(config.labels(), ["main", "w1"]);
    }

    #[test]
    fn parses_options_and_rejects_bad_ones() {
        let config = parse(&["--data-mib", "0", "--windows", "4", "--report", "r.json"]).unwrap();
        assert_eq!(config.data_mib, 0);
        assert_eq!(config.labels(), ["main", "w1", "w2", "w3"]);
        assert!(config.automated);
        assert!(parse(&["--data-mib", "257"]).is_err());
        assert!(parse(&["--windows", "0"]).is_err());
        assert!(parse(&["--windows", "9"]).is_err());
        assert!(parse(&["--step-interval-ms", "50"]).is_err());
        assert!(parse(&["--bogus", "1"]).is_err());
        assert!(parse(&["--duration"]).is_err());
    }
}
