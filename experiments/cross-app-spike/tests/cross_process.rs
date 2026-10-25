//! End-to-end checks with real, separately launched OS processes: one
//! `spike-broker` and several `spike-client` processes (copied to distinct
//! paths so that the broker can tell the applications apart). The test
//! process itself connects as a registered observer to read broker stats.
//!
//! `--op-delay-ms` only creates deterministic overlap. Nothing here measures
//! time, CPU or memory.

use cross_app_spike::client::{Client, ClientError};
use cross_app_spike::ops::{self, AppNote, AppNoteParams, Checksum, ChecksumParams};
use cross_app_spike::protocol::ErrorCode;
use cross_app_spike::transport::Endpoint;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

const BROKER: &str = env!("CARGO_BIN_EXE_spike-broker");
const CLIENT: &str = env!("CARGO_BIN_EXE_spike-client");
const TEST_TIMEOUT: Duration = Duration::from_secs(60);

struct Fixture {
    dir: PathBuf,
    endpoint: Endpoint,
    manifest: PathBuf,
    alpha: PathBuf,
    beta: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("tmwr-spike-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        #[cfg(windows)]
        let endpoint = Endpoint::new(format!(
            r"\\.\pipe\tmwr-spike-test-{}-{name}",
            std::process::id()
        ));
        #[cfg(unix)]
        let endpoint = Endpoint::new(dir.join("broker.sock"));

        let exe = |stem: &str| dir.join(format!("{stem}{}", std::env::consts::EXE_SUFFIX));
        let (alpha, beta) = (exe("alpha-client"), exe("beta-client"));
        std::fs::copy(CLIENT, &alpha).unwrap();
        std::fs::copy(CLIENT, &beta).unwrap();

        let observer = std::env::current_exe().unwrap();
        let manifest = dir.join("manifest.json");
        let app_grants = ["fixture.checksum@1", "fixture.appNote@1", "fixture.fail@1"];
        let manifest_json = json!({ "apps": [
            { "appId": "demo.alpha", "executable": alpha, "grants": app_grants },
            { "appId": "demo.beta", "executable": beta, "grants": app_grants },
            { "appId": "test.observer", "executable": observer, "grants": [
                "fixture.checksum@1", "fixture.appNote@1", "fixture.fail@1",
                "invalidate:fixture.checksum@1", "invalidate:fixture.appNote@1", "stats"] },
            { "appId": "test.limited", "executable": observer, "grants": ["fixture.checksum@1"] },
        ]});
        std::fs::write(
            &manifest,
            serde_json::to_vec_pretty(&manifest_json).unwrap(),
        )
        .unwrap();
        Self {
            dir,
            endpoint,
            manifest,
            alpha,
            beta,
        }
    }

    async fn broker(&self, extra: &[&str]) -> Broker {
        let mut child = Command::new(BROKER)
            .arg("--endpoint")
            .arg(&self.endpoint.0)
            .arg("--manifest")
            .arg(&self.manifest)
            .args(extra)
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let first: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(first["event"], "listening", "{first}");
        Broker {
            child,
            lines,
            instance_id: first["instanceId"].as_str().unwrap().to_string(),
        }
    }

    fn client(&self, exe: &Path, app_id: &str, args: &[&str]) -> Child {
        Command::new(exe)
            .arg("--endpoint")
            .arg(&self.endpoint.0)
            .arg("--app-id")
            .arg(app_id)
            .args(args)
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap()
    }

    async fn observer(&self) -> Client {
        Client::connect(&self.endpoint, "test.observer")
            .await
            .unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Broker {
    child: Child,
    lines: tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    instance_id: String,
}

/// Runs a client to completion; returns its exit code and JSON lines.
async fn finish(child: Child) -> (i32, Vec<Value>) {
    let output = child.wait_with_output().await.unwrap();
    let lines = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    (output.status.code().unwrap_or(-1), lines)
}

fn last_event<'a>(lines: &'a [Value], event: &str) -> &'a Value {
    lines
        .iter()
        .rev()
        .find(|l| l["event"] == event)
        .unwrap_or_else(|| panic!("no {event} in {lines:?}"))
}

async fn op_stats(observer: &Client, op: &str) -> Value {
    observer.stats().await.unwrap()["ops"][op].clone()
}

async fn wait_until<F>(observer: &Client, what: &str, mut ready: F)
where
    F: FnMut(&Value) -> bool,
{
    for _ in 0..400 {
        if ready(&observer.stats().await.unwrap()) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out waiting for {what}");
}

fn in_flight(op: &'static str, at_least: u64) -> impl FnMut(&Value) -> bool {
    move |stats| stats["ops"][op]["inFlight"].as_u64().unwrap_or(0) >= at_least
}

fn oracle(seed: u32, size_kib: u32) -> Value {
    serde_json::to_value(ops::checksum(&ChecksumParams { seed, size_kib })).unwrap()
}

async fn with_timeout<F: std::future::Future<Output = ()>>(test: F) {
    tokio::time::timeout(TEST_TIMEOUT, test)
        .await
        .expect("test timed out");
}

#[tokio::test(flavor = "multi_thread")]
async fn two_processes_share_one_public_execution() {
    with_timeout(async {
        let fx = Fixture::new("public");
        let _broker = fx.broker(&["--op-delay-ms", "800"]).await;
        let observer = fx.observer().await;

        let alpha = fx.client(&fx.alpha, "demo.alpha", &["checksum", "7", "1024"]);
        wait_until(
            &observer,
            "alpha in flight",
            in_flight("fixture.checksum@1", 1),
        )
        .await;
        let beta = fx.client(&fx.beta, "demo.beta", &["checksum", "7", "1024"]);
        let ((a_code, a), (b_code, b)) = tokio::join!(finish(alpha), finish(beta));
        assert_eq!((a_code, b_code), (0, 0), "{a:?} {b:?}");

        let (a, b) = (last_event(&a, "result"), last_event(&b, "result"));
        assert_eq!(a["kind"], "executed");
        assert_eq!(b["kind"], "coalesced", "beta joined alpha's in-flight call");
        assert_eq!(a["value"], oracle(7, 1024));
        assert_eq!(b["value"], oracle(7, 1024));

        // A third, later process gets the cached value.
        let (_, c) = finish(fx.client(&fx.beta, "demo.beta", &["checksum", "7", "1024"])).await;
        assert_eq!(last_event(&c, "result")["kind"], "cacheHit");

        let stats = op_stats(&observer, "fixture.checksum@1").await;
        assert_eq!(stats["executions"], 1, "{stats}");
        assert_eq!(stats["coalesced"], 1, "{stats}");
        assert_eq!(stats["cacheHits"], 1, "{stats}");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn app_scope_is_never_shared_between_applications() {
    with_timeout(async {
        let fx = Fixture::new("appscope");
        let _broker = fx.broker(&["--op-delay-ms", "800"]).await;
        let observer = fx.observer().await;

        // Same operation and parameters, concurrently, from two applications.
        let alpha = fx.client(&fx.alpha, "demo.alpha", &["note", "9"]);
        wait_until(
            &observer,
            "alpha in flight",
            in_flight("fixture.appNote@1", 1),
        )
        .await;
        let beta = fx.client(&fx.beta, "demo.beta", &["note", "9"]);
        let ((_, a), (_, b)) = tokio::join!(finish(alpha), finish(beta));
        let (a, b) = (last_event(&a, "result"), last_event(&b, "result"));
        assert_eq!(a["kind"], "executed");
        assert_eq!(
            b["kind"], "executed",
            "beta must not join alpha's call: {b}"
        );
        assert_eq!(a["value"]["appId"], "demo.alpha");
        assert_eq!(b["value"]["appId"], "demo.beta");

        // A second alpha process shares alpha's cache entry, and only that.
        let (_, again) = finish(fx.client(&fx.alpha, "demo.alpha", &["note", "9"])).await;
        let again = last_event(&again, "result");
        assert_eq!(again["kind"], "cacheHit");
        assert_eq!(again["value"]["appId"], "demo.alpha");

        let stats = op_stats(&observer, "fixture.appNote@1").await;
        assert_eq!(stats["executions"], 2, "{stats}");
        assert_eq!(stats["coalesced"], 0, "{stats}");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn claims_that_the_os_does_not_back_are_rejected() {
    with_timeout(async {
        let fx = Fixture::new("identity");
        let _broker = fx.broker(&[]).await;

        // The beta binary claims to be alpha.
        let (code, lines) =
            finish(fx.client(&fx.beta, "demo.alpha", &["checksum", "1", "1"])).await;
        assert_eq!(code, 3, "{lines:?}");
        assert_eq!(last_event(&lines, "rejected")["code"], "identityMismatch");

        let (code, lines) =
            finish(fx.client(&fx.alpha, "demo.unknown", &["checksum", "1", "1"])).await;
        assert_eq!(code, 3);
        assert_eq!(last_event(&lines, "rejected")["code"], "notRegistered");

        let err = Client::connect_with_versions(&fx.endpoint, "test.observer", 2, 3)
            .await
            .err()
            .unwrap();
        assert_eq!(err.code(), ErrorCode::VersionMismatch);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn grants_and_parameters_are_enforced_by_the_broker() {
    with_timeout(async {
        let fx = Fixture::new("grants");
        let _broker = fx.broker(&[]).await;
        let observer = fx.observer().await;
        let limited = Client::connect(&fx.endpoint, "test.limited").await.unwrap();

        let offered: Vec<_> = limited
            .welcome()
            .operations
            .iter()
            .map(|d| d.name.clone())
            .collect();
        assert_eq!(offered, ["fixture.checksum"]);
        assert_eq!(code(limited.stats().await), Some(ErrorCode::NotPermitted));
        assert_eq!(
            code(limited.call::<AppNote>(&AppNoteParams { n: 1 }).await),
            Some(ErrorCode::NotPermitted)
        );
        assert_eq!(
            code(
                limited
                    .invalidate::<Checksum>(&ChecksumParams {
                        seed: 1,
                        size_kib: 1
                    })
                    .await
            ),
            Some(ErrorCode::NotPermitted)
        );

        // Unknown operation, unknown version, a smuggled field, out-of-range input.
        for (op, version, params, expected) in [
            ("fixture.secret", 1, json!({}), ErrorCode::UnknownOperation),
            (
                "fixture.checksum",
                2,
                json!({"seed": 1, "sizeKib": 1}),
                ErrorCode::UnknownOperation,
            ),
            (
                "fixture.checksum",
                1,
                json!({"seed": 1, "sizeKib": 1, "scope": "public"}),
                ErrorCode::InvalidParams,
            ),
            (
                "fixture.checksum",
                1,
                json!({"seed": 1, "sizeKib": 0}),
                ErrorCode::InvalidParams,
            ),
        ] {
            let stats = observer.stats().await.unwrap();
            let reply = raw_call(&limited, op, version, params).await;
            assert_eq!(reply, Some(expected), "{op}@{version}");
            assert_eq!(
                observer.stats().await.unwrap()["ops"],
                stats["ops"],
                "nothing ran"
            );
        }
    })
    .await;
}

fn code<T>(result: Result<T, ClientError>) -> Option<ErrorCode> {
    result.err().map(|e| e.code())
}

async fn raw_call(client: &Client, op: &str, version: u16, params: Value) -> Option<ErrorCode> {
    client
        .call_raw(op, version, params)
        .await
        .err()
        .map(|e| e.code())
}

#[tokio::test(flavor = "multi_thread")]
async fn errors_are_never_cached_or_shared_late() {
    with_timeout(async {
        let fx = Fixture::new("errors");
        let _broker = fx.broker(&[]).await;
        let observer = fx.observer().await;
        for exe in [&fx.alpha, &fx.beta] {
            let app = if exe == &fx.alpha {
                "demo.alpha"
            } else {
                "demo.beta"
            };
            let (_, lines) = finish(fx.client(exe, app, &["fail", "3"])).await;
            assert_eq!(last_event(&lines, "error")["code"], "operationFailed");
        }
        let stats = op_stats(&observer, "fixture.fail@1").await;
        assert_eq!(stats["executions"], 2, "{stats}");
        assert_eq!(stats["cachedEntries"], 0, "{stats}");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_call_delivers_nothing_and_caches_nothing() {
    with_timeout(async {
        let fx = Fixture::new("cancel");
        let _broker = fx.broker(&["--op-delay-ms", "800"]).await;
        let observer = fx.observer().await;

        let (_, lines) = finish(fx.client(
            &fx.alpha,
            "demo.alpha",
            &["cancel-checksum", "11", "64", "200", "1000"],
        ))
        .await;
        let cancelled = last_event(&lines, "cancelled");
        assert_eq!(cancelled["delivered"], false, "{cancelled}");
        assert_eq!(
            cancelled["lateRepliesDropped"], 0,
            "the broker sent nothing after cancel"
        );
        wait_until(&observer, "idle", |s| {
            s["ops"]["fixture.checksum@1"]["inFlight"] == 0
        })
        .await;
        let stats = op_stats(&observer, "fixture.checksum@1").await;
        assert_eq!(stats["cachedEntries"], 0, "{stats}");

        // So the next caller executes afresh.
        let (_, lines) = finish(fx.client(&fx.beta, "demo.beta", &["checksum", "11", "64"])).await;
        let result = last_event(&lines, "result");
        assert_eq!(result["kind"], "executed");
        assert_eq!(result["value"], oracle(11, 64));
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn cancelling_the_initiator_does_not_strand_another_application() {
    with_timeout(async {
        let fx = Fixture::new("cancel-shared");
        let _broker = fx.broker(&["--op-delay-ms", "800"]).await;
        let observer = fx.observer().await;

        let alpha = fx.client(
            &fx.alpha,
            "demo.alpha",
            &["cancel-checksum", "12", "64", "300", "0"],
        );
        wait_until(
            &observer,
            "alpha in flight",
            in_flight("fixture.checksum@1", 1),
        )
        .await;
        let beta = fx.client(&fx.beta, "demo.beta", &["checksum", "12", "64"]);
        let ((_, a), (_, b)) = tokio::join!(finish(alpha), finish(beta));
        assert_eq!(last_event(&a, "cancelled")["delivered"], false);
        let b = last_event(&b, "result");
        assert_eq!(
            b["value"],
            oracle(12, 64),
            "beta still gets a correct result: {b}"
        );

        // Core V3: the remaining waiter re-runs the operation.
        let stats = op_stats(&observer, "fixture.checksum@1").await;
        assert_eq!(stats["executions"], 2, "{stats}");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_killed_client_does_not_disturb_the_others() {
    with_timeout(async {
        let fx = Fixture::new("kill-client");
        let _broker = fx.broker(&["--op-delay-ms", "800"]).await;
        let observer = fx.observer().await;

        let mut alpha = fx.client(&fx.alpha, "demo.alpha", &["checksum", "13", "64"]);
        wait_until(
            &observer,
            "alpha in flight",
            in_flight("fixture.checksum@1", 1),
        )
        .await;
        alpha.kill().await.unwrap();
        wait_until(&observer, "alpha's call aborted", |s| {
            s["ops"]["fixture.checksum@1"]["inFlight"] == 0
        })
        .await;

        let (_, lines) = finish(fx.client(&fx.beta, "demo.beta", &["checksum", "13", "64"])).await;
        assert_eq!(last_event(&lines, "result")["value"], oracle(13, 64));
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_broker_crash_is_survived_by_reconnecting_to_a_new_instance() {
    with_timeout(async {
        let fx = Fixture::new("restart");
        let mut first = fx.broker(&["--op-delay-ms", "1500"]).await;
        let observer = fx.observer().await;

        let client = fx.client(
            &fx.alpha,
            "demo.alpha",
            &["checksum-retry", "21", "64", "40"],
        );
        wait_until(
            &observer,
            "call in flight",
            in_flight("fixture.checksum@1", 1),
        )
        .await;
        first.child.kill().await.unwrap();
        let _ = first.child.wait().await;

        let second = fx.broker(&["--op-delay-ms", "100"]).await;
        assert_ne!(second.instance_id, first.instance_id);
        let (code, lines) = finish(client).await;
        assert_eq!(code, 0, "{lines:?}");
        let result = last_event(&lines, "result");
        assert_eq!(result["value"], oracle(21, 64));
        assert_eq!(
            result["instanceId"],
            second.instance_id.as_str(),
            "served by the new broker"
        );
        assert!(result["reconnects"].as_u64().unwrap() >= 1, "{result}");

        // The observer's old connection is gone, not silently re-pointed.
        assert_eq!(
            observer.stats().await.err().map(|e| e.code()),
            Some(ErrorCode::BrokerUnavailable)
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn only_one_broker_owns_an_endpoint_and_it_exits_when_idle() {
    with_timeout(async {
        let fx = Fixture::new("single");
        let mut first = fx.broker(&["--idle-exit-ms", "300"]).await;

        let second = Command::new(BROKER)
            .arg("--endpoint")
            .arg(&fx.endpoint.0)
            .arg("--manifest")
            .arg(&fx.manifest)
            .output()
            .await
            .unwrap();
        assert_eq!(second.status.code(), Some(3), "{second:?}");

        let (_, lines) = finish(fx.client(&fx.alpha, "demo.alpha", &["checksum", "1", "1"])).await;
        last_event(&lines, "result");
        let status = tokio::time::timeout(Duration::from_secs(10), first.child.wait())
            .await
            .expect("broker should exit when idle")
            .unwrap();
        assert!(status.success());
        let line = first.lines.next_line().await.unwrap().unwrap();
        assert!(line.contains("idleExit"), "{line}");
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn notices_reach_only_clients_that_can_read_the_scope() {
    with_timeout(async {
        let fx = Fixture::new("notices");
        let _broker = fx.broker(&[]).await;
        let observer = fx.observer().await;

        let alpha = fx.client(&fx.alpha, "demo.alpha", &["listen", "1500"]);
        let beta = fx.client(&fx.beta, "demo.beta", &["listen", "1500"]);
        wait_until(&observer, "listeners", |s| {
            s["connections"].as_u64().unwrap_or(0) >= 3
        })
        .await;

        // App scope: the observer's own key. Nobody else may learn about it.
        observer
            .invalidate::<AppNote>(&AppNoteParams { n: 1 })
            .await
            .unwrap();
        // Public scope: everyone holding the grant gets a data-free hint.
        observer
            .invalidate::<Checksum>(&ChecksumParams {
                seed: 1,
                size_kib: 1,
            })
            .await
            .unwrap();

        for (_, lines) in [finish(alpha).await, finish(beta).await] {
            let notices: Vec<_> = lines.iter().filter(|l| l["event"] == "notice").collect();
            assert_eq!(notices.len(), 1, "{lines:?}");
            assert_eq!(notices[0]["notice"]["scope"], "public");
            assert_eq!(notices[0]["notice"]["op"], "fixture.checksum");
            assert!(notices[0]["notice"].get("params").is_none());
        }
        let own = observer.next_notice(Duration::from_secs(1)).await;
        assert!(own.is_some(), "the observer sees its own app-scope notice");
    })
    .await;
}
