//! Coordination of the windows of one run, kept in Rust so that every window
//! sees one plan and one clock. Windows poll; Tauri events are not buffered.

use crate::workload::Workload;
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    sync::Mutex,
};

/// Lead time between `begin` and the first idle phase, so that every window
/// has fetched the plan before it starts.
pub const PLAN_LEAD_MS: u64 = 3_000;
/// Largest window report accepted.
pub const MAX_WINDOW_REPORT_BYTES: usize = 1 << 20;

/// Phase boundaries as Unix milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub idle_before_at_ms: u64,
    pub warmup_at_ms: u64,
    pub load_at_ms: u64,
    pub load_end_ms: u64,
    pub idle_after_end_ms: u64,
}

impl Plan {
    pub fn new(
        now_ms: u64,
        idle_before_s: u32,
        warmup_s: u32,
        load_s: u32,
        idle_after_s: u32,
    ) -> Self {
        let idle_before_at_ms = now_ms + PLAN_LEAD_MS;
        let warmup_at_ms = idle_before_at_ms + u64::from(idle_before_s) * 1000;
        let load_at_ms = warmup_at_ms + u64::from(warmup_s) * 1000;
        let load_end_ms = load_at_ms + u64::from(load_s) * 1000;
        Self {
            idle_before_at_ms,
            warmup_at_ms,
            load_at_ms,
            load_end_ms,
            idle_after_end_ms: load_end_ms + u64::from(idle_after_s) * 1000,
        }
    }
}

#[derive(Default)]
struct State {
    ready: BTreeSet<String>,
    plan: Option<Plan>,
    workloads: HashMap<String, Workload>,
    reports: BTreeMap<String, serde_json::Value>,
}

pub struct Coordinator {
    labels: Vec<String>,
    state: Mutex<State>,
}

impl Coordinator {
    pub fn new(labels: Vec<String>) -> Self {
        Self {
            labels,
            state: Mutex::new(State::default()),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn known(&self, label: &str) -> Result<(), String> {
        if self.labels.iter().any(|l| l == label) {
            Ok(())
        } else {
            Err(format!("unknown window {label:?}"))
        }
    }

    /// Windows that reported ready, in label order.
    pub fn mark_ready(&self, label: &str) -> Result<Vec<String>, String> {
        self.known(label)?;
        let mut state = self.state();
        state.ready.insert(label.to_owned());
        Ok(state.ready.iter().cloned().collect())
    }

    pub fn all_ready(&self) -> bool {
        self.state().ready.len() == self.labels.len()
    }

    /// Fixes the plan and every window's workload. `workload` is called with
    /// each window's index (position in the label list).
    pub fn begin(
        &self,
        plan: Plan,
        mut workload: impl FnMut(u32) -> Workload,
    ) -> Result<Plan, String> {
        if !self.all_ready() {
            return Err("not every window is ready".to_owned());
        }
        let workloads = self
            .labels
            .iter()
            .enumerate()
            .map(|(index, label)| (label.clone(), workload(index as u32)))
            .collect();
        let mut state = self.state();
        if state.plan.is_some() {
            return Err("the run has already begun".to_owned());
        }
        state.workloads = workloads;
        state.plan = Some(plan);
        Ok(plan)
    }

    pub fn plan(&self) -> Option<Plan> {
        self.state().plan
    }

    pub fn workload(&self, label: &str) -> Result<Workload, String> {
        self.known(label)?;
        self.state()
            .workloads
            .get(label)
            .cloned()
            .ok_or_else(|| "the run has not begun".to_owned())
    }

    pub fn report(&self, label: &str, report: &str) -> Result<(), String> {
        self.known(label)?;
        if report.len() > MAX_WINDOW_REPORT_BYTES {
            return Err(format!(
                "window report has {} bytes, the limit is {MAX_WINDOW_REPORT_BYTES}",
                report.len()
            ));
        }
        let value: serde_json::Value =
            serde_json::from_str(report).map_err(|e| format!("window report is not JSON: {e}"))?;
        let mut state = self.state();
        if state.reports.contains_key(label) {
            return Err(format!("window {label} already reported"));
        }
        state.reports.insert(label.to_owned(), value);
        Ok(())
    }

    /// Every window's report once all have reported; otherwise the labels
    /// still missing.
    pub fn collect(&self) -> Result<BTreeMap<String, serde_json::Value>, Vec<String>> {
        let state = self.state();
        let missing: Vec<String> = self
            .labels
            .iter()
            .filter(|l| !state.reports.contains_key(*l))
            .cloned()
            .collect();
        if missing.is_empty() {
            Ok(state.reports.clone())
        } else {
            Err(missing)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn workload(index: u32) -> Workload {
        Workload {
            window_index: index,
            steps: Vec::new(),
            expected: Vec::new(),
        }
    }

    #[test]
    fn plan_phases_follow_each_other() {
        let plan = Plan::new(1_000, 20, 30, 120, 30);
        assert_eq!(plan.idle_before_at_ms, 4_000);
        assert_eq!(plan.warmup_at_ms, 24_000);
        assert_eq!(plan.load_at_ms, 54_000);
        assert_eq!(plan.load_end_ms, 174_000);
        assert_eq!(plan.idle_after_end_ms, 204_000);
    }

    #[test]
    fn begins_once_after_every_window_is_ready() {
        let c = Coordinator::new(vec!["main".into(), "w1".into()]);
        let plan = Plan::new(0, 0, 0, 1, 0);
        assert!(c.mark_ready("w9").is_err());
        assert_eq!(c.mark_ready("main").unwrap(), ["main"]);
        assert!(c.begin(plan, workload).is_err(), "w1 is not ready");
        assert!(c.workload("w1").is_err());
        c.mark_ready("w1").unwrap();
        assert_eq!(c.begin(plan, workload).unwrap(), plan);
        assert!(c.begin(plan, workload).is_err(), "began twice");
        assert_eq!(c.plan(), Some(plan));
        assert_eq!(c.workload("w1").unwrap().window_index, 1);
        assert_eq!(c.workload("main").unwrap().window_index, 0);
    }

    #[test]
    fn collects_one_bounded_json_report_per_window() {
        let c = Coordinator::new(vec!["main".into(), "w1".into()]);
        c.report("main", r#"{"steps": 3}"#).unwrap();
        assert!(c.report("main", "{}").is_err(), "reported twice");
        assert!(c.report("w1", "not json").is_err());
        assert!(
            c.report(
                "w1",
                &format!("\"{}\"", "x".repeat(MAX_WINDOW_REPORT_BYTES))
            )
            .is_err()
        );
        assert_eq!(c.collect().unwrap_err(), ["w1"]);
        c.report("w1", "{}").unwrap();
        let reports = c.collect().unwrap();
        assert_eq!(reports["main"]["steps"], 3);
    }
}
