//! A headless test application. Each run is a separate OS process, launched
//! independently of the broker and of the other client.
//!
//! `spike-client --endpoint E --app-id A <command> [args]`, commands:
//! - `checksum SEED SIZE_KIB [REPEAT]`
//! - `checksum-retry SEED SIZE_KIB ATTEMPTS` (reconnects after a broker loss)
//! - `note N`
//! - `fail CODE`
//! - `cancel-checksum SEED SIZE_KIB AFTER_MS GRACE_MS`
//! - `listen MS` (prints notices)
//!
//! Output is one JSON object per line. Exit code 3 means the handshake was rejected.

use cross_app_spike::client::{Client, ClientError, Session};
use cross_app_spike::ops::{AppNote, AppNoteParams, Checksum, ChecksumParams, Fail, FailParams};
use cross_app_spike::transport::Endpoint;
use serde_json::{Value, json};
use std::process::ExitCode;
use std::time::Duration;

fn emit(value: Value) {
    println!("{value}");
}

fn error_json(err: &ClientError) -> Value {
    json!({"event": "error", "code": err.code(), "detail": err.to_string()})
}

#[tokio::main]
async fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut take_flag = |name: &str| {
        let at = args.iter().position(|a| a == name)?;
        let value = args.get(at + 1).cloned();
        args.drain(at..(at + 2).min(args.len()));
        value
    };
    let endpoint = take_flag("--endpoint")
        .map(Endpoint::new)
        .unwrap_or_else(Endpoint::default_for_user);
    let Some(app_id) = take_flag("--app-id") else {
        eprintln!("--app-id is required");
        return ExitCode::from(2);
    };
    let num = |i: usize| -> u64 { args.get(i).and_then(|v| v.parse().ok()).unwrap_or(0) };
    let command = args.first().cloned().unwrap_or_default();

    if command == "checksum-retry" {
        let mut session = Session::new(endpoint, app_id);
        let params = ChecksumParams {
            seed: num(1) as u32,
            size_kib: num(2) as u32,
        };
        return match session.call::<Checksum>(&params, num(3) as u32).await {
            Ok(ok) => {
                let welcome = session.client().map(|c| c.welcome().instance_id.clone());
                emit(
                    json!({"event": "result", "kind": ok.kind, "value": ok.value,
                    "instanceId": welcome, "reconnects": session.reconnects}),
                );
                ExitCode::SUCCESS
            }
            Err(err) => {
                emit(error_json(&err));
                ExitCode::from(1)
            }
        };
    }

    let client = match Client::connect(&endpoint, &app_id).await {
        Ok(client) => client,
        Err(err @ ClientError::Rejected { .. }) => {
            emit(json!({"event": "rejected", "code": err.code(), "detail": err.to_string()}));
            return ExitCode::from(3);
        }
        Err(err) => {
            emit(error_json(&err));
            return ExitCode::from(1);
        }
    };
    let w = client.welcome();
    emit(
        json!({"event": "welcome", "appId": w.app_id, "instanceId": w.instance_id,
        "protocol": w.protocol, "operations": w.operations}),
    );

    match command.as_str() {
        "checksum" => {
            let params = ChecksumParams {
                seed: num(1) as u32,
                size_kib: num(2) as u32,
            };
            for _ in 0..num(3).max(1) {
                match client.call::<Checksum>(&params).await {
                    Ok(ok) => emit(json!({"event": "result", "kind": ok.kind, "value": ok.value})),
                    Err(err) => emit(error_json(&err)),
                }
            }
        }
        "note" => match client
            .call::<AppNote>(&AppNoteParams { n: num(1) as u32 })
            .await
        {
            Ok(ok) => emit(json!({"event": "result", "kind": ok.kind, "value": ok.value})),
            Err(err) => emit(error_json(&err)),
        },
        "fail" => match client
            .call::<Fail>(&FailParams {
                code: num(1) as u32,
            })
            .await
        {
            Ok(ok) => emit(json!({"event": "result", "kind": ok.kind, "value": ok.value})),
            Err(err) => emit(error_json(&err)),
        },
        "cancel-checksum" => {
            let params = ChecksumParams {
                seed: num(1) as u32,
                size_kib: num(2) as u32,
            };
            let call = match client.start::<Checksum>(&params, None).await {
                Ok(call) => call,
                Err(err) => {
                    emit(error_json(&err));
                    return ExitCode::from(1);
                }
            };
            tokio::time::sleep(Duration::from_millis(num(3))).await;
            let _ = client.cancel(call.id).await;
            let outcome = call.wait().await;
            tokio::time::sleep(Duration::from_millis(num(4))).await;
            emit(json!({"event": "cancelled", "delivered": outcome.is_ok(),
                "lateRepliesDropped": client.late_replies_dropped()}));
        }
        "listen" => {
            let deadline = tokio::time::Instant::now() + Duration::from_millis(num(1));
            emit(json!({"event": "listening"}));
            while let Some(left) = deadline.checked_duration_since(tokio::time::Instant::now()) {
                match client.next_notice(left).await {
                    Some(event) => emit(json!({"event": "notice", "notice": event})),
                    None => break,
                }
            }
            emit(json!({"event": "done"}));
        }
        other => {
            eprintln!("unknown command {other:?}");
            return ExitCode::from(2);
        }
    }
    ExitCode::SUCCESS
}
