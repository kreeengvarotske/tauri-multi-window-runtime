//! The demo's commands through Tauri's real IPC path (mock runtime): ACL
//! checks from `capabilities/`, the injected window, request and response
//! limits, window destroy and exit.

use runtime_adapter_demo::{DemoConfig, PAGE_MAX_REQUEST_BYTES, app, runtime};
use serde_json::{Value, json};
use tauri::{
    Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
    ipc::{CallbackFn, InvokeBody, InvokeResponseBody},
    test::{INVOKE_KEY, MockRuntime, get_ipc_response, mock_builder},
    webview::InvokeRequest,
};

fn build(config: DemoConfig) -> tauri::App<MockRuntime> {
    app(mock_builder(), runtime(config).unwrap())
        .build(tauri::generate_context!())
        .expect("demo app builds")
}

fn window(app: &tauri::App<MockRuntime>, label: &str) -> WebviewWindow<MockRuntime> {
    match app.get_webview_window(label) {
        Some(window) => window,
        None => WebviewWindowBuilder::new(app, label, WebviewUrl::default())
            .build()
            .unwrap(),
    }
}

fn invoke(
    window: &WebviewWindow<MockRuntime>,
    cmd: &str,
    body: InvokeBody,
) -> Result<Value, Value> {
    let request = InvokeRequest {
        cmd: cmd.into(),
        callback: CallbackFn(0),
        error: CallbackFn(1),
        url: if cfg!(any(windows, target_os = "android")) {
            "http://tauri.localhost"
        } else {
            "tauri://localhost"
        }
        .parse()
        .unwrap(),
        body,
        headers: Default::default(),
        invoke_key: INVOKE_KEY.to_string(),
    };
    get_ipc_response(window, request).map(|body| match body {
        InvokeResponseBody::Raw(bytes) => serde_json::from_slice(&bytes).expect("JSON response"),
        InvokeResponseBody::Json(text) => serde_json::from_str(&text).unwrap(),
    })
}

fn raw(value: Value) -> InvokeBody {
    InvokeBody::Raw(serde_json::to_vec(&value).unwrap())
}

fn code(error: &Value) -> &str {
    error["code"]
        .as_str()
        .unwrap_or_else(|| panic!("no code in {error}"))
}

#[test]
fn every_window_reads_the_same_shared_catalog() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    let w1 = window(&app, "w1");
    let a = invoke(
        &main,
        "demo_catalog_page",
        raw(json!({ "offset": 10, "limit": 3 })),
    )
    .unwrap();
    let b = invoke(
        &w1,
        "demo_catalog_page",
        raw(json!({ "offset": 10, "limit": 3 })),
    )
    .unwrap();
    assert_eq!(a, b);
    assert_eq!(a["total"], 10_000);
    assert_eq!(a["items"][0], json!({ "id": 10, "name": "item 00010" }));
    let stats = invoke(&main, "demo_stats", InvokeBody::default()).unwrap();
    let catalog = stats
        .as_array()
        .unwrap()
        .iter()
        .find(|op| op["name"] == "demo.catalog")
        .unwrap();
    assert_eq!(
        catalog["executed"], 1,
        "one execution for both windows: {stats}"
    );
}

#[test]
fn json_object_bodies_are_accepted_within_the_limit() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    let page = invoke(
        &main,
        "demo_catalog_page",
        InvokeBody::Json(json!({ "offset": 0, "limit": 1 })),
    )
    .unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 1);
}

#[test]
fn capabilities_decide_which_window_runs_a_command() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    let w1 = window(&app, "w1");
    let stranger = window(&app, "other");
    assert!(invoke(&main, "demo_stats", InvokeBody::default()).is_ok());
    // Not granted to w1 (only "main" has the stats capability) …
    let denied = invoke(&w1, "demo_stats", InvokeBody::default()).unwrap_err();
    assert!(
        denied
            .as_str()
            .is_some_and(|text| text.contains("not allowed")),
        "{denied}"
    );
    // … and a window matching no capability runs nothing.
    let denied = invoke(
        &stranger,
        "demo_catalog_page",
        raw(json!({ "offset": 0, "limit": 1 })),
    )
    .unwrap_err();
    assert!(
        denied
            .as_str()
            .is_some_and(|text| text.contains("not allowed")),
        "{denied}"
    );
}

#[test]
fn oversized_request_is_refused_with_a_stable_code() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    let padding = " ".repeat(PAGE_MAX_REQUEST_BYTES);
    let body = InvokeBody::Raw(format!(r#"{{"offset":0,"limit":1}}{padding}"#).into_bytes());
    let error = invoke(&main, "demo_catalog_page", body).unwrap_err();
    assert_eq!(
        error,
        json!({ "code": "REQUEST_TOO_LARGE", "message": format!("request body is larger than {PAGE_MAX_REQUEST_BYTES} bytes") })
    );
}

#[test]
fn invalid_requests_have_stable_codes() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    for body in [
        InvokeBody::Raw(b"{".to_vec()),
        raw(json!({ "offset": 0 })),
        raw(json!({ "offset": 0, "limit": 0 })),
        raw(json!({ "offset": 0, "limit": 101 })),
    ] {
        let error = invoke(&main, "demo_catalog_page", body).unwrap_err();
        assert_eq!(code(&error), "INVALID_ARGUMENT", "{error}");
    }
}

#[test]
fn a_forged_window_or_scope_in_the_request_is_refused() {
    let app = build(DemoConfig::default());
    let w1 = window(&app, "w1");
    for forged in [
        json!({ "offset": 0, "limit": 1, "window": "main" }),
        json!({ "offset": 0, "limit": 1, "scope": "shared" }),
        json!({ "offset": 0, "limit": 1, "operation": "demo.window-note" }),
    ] {
        let error = invoke(&w1, "demo_catalog_page", raw(forged)).unwrap_err();
        assert_eq!(code(&error), "INVALID_ARGUMENT", "{error}");
        // Only the class leaves: no serde text naming the forged field.
        assert_eq!(error["message"], "invalid request", "{error}");
    }
}

#[test]
fn refused_requests_do_not_echo_their_content_to_the_webview() {
    const SENTINEL: &str = "sentinel-7f3a9c";
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    for body in [
        // Unknown field, malformed value, and a value the view itself refuses.
        raw(json!({ "offset": 0, "limit": 1, SENTINEL: true })),
        raw(json!({ "offset": SENTINEL, "limit": 1 })),
        InvokeBody::Raw(format!(r#"{{"offset":0,"limit":"{SENTINEL}"#).into_bytes()),
        raw(json!({ "offset": 0, "limit": 0 })),
    ] {
        let error = invoke(&main, "demo_catalog_page", body).unwrap_err();
        let envelope = error.to_string();
        assert_eq!(code(&error), "INVALID_ARGUMENT", "{envelope}");
        assert_eq!(error["message"], "invalid request", "{envelope}");
        assert!(!envelope.contains(SENTINEL), "{envelope}");
        assert!(!envelope.contains("limit"), "{envelope}");
    }
}

#[test]
fn per_window_data_follows_the_injected_window() {
    let app = build(DemoConfig::default());
    let main = window(&app, "main");
    let w1 = window(&app, "w1");
    let main_note = invoke(&main, "demo_window_note", InvokeBody::default()).unwrap();
    let w1_note = invoke(&w1, "demo_window_note", InvokeBody::default()).unwrap();
    assert_ne!(main_note, w1_note);
    // Cached per window; a body naming another window changes nothing.
    assert_eq!(
        invoke(&main, "demo_window_note", raw(json!({ "window": "w1" }))).unwrap(),
        main_note
    );
    assert_eq!(
        invoke(&w1, "demo_window_note", InvokeBody::default()).unwrap(),
        w1_note
    );
}

/// The mock runtime emits `RunEvent::Exit` once its last window is gone
/// (it implements neither `exit` nor `WindowEvent::Destroyed`; those two are
/// checked on a real window system by the demo's `--self-test`).
#[test]
fn exit_shuts_the_runtime_down() {
    // `main` comes from tauri.conf.json and is created when the app runs.
    let app = build(DemoConfig::default());
    let handle = app.handle().clone();
    let mut destroyed = false;
    let code = app.run_return(move |app, event| {
        if matches!(event, tauri::RunEvent::Ready) && !destroyed {
            destroyed = true;
            let main = app
                .get_webview_window("main")
                .expect("main from the config");
            assert!(
                invoke(
                    &main,
                    "demo_catalog_page",
                    raw(json!({ "offset": 0, "limit": 1 }))
                )
                .is_ok()
            );
            assert!(
                app.state::<shared_runtime_tauri::SharedRuntime>()
                    .runtime()
                    .stats()
                    .cache_weight_bytes()
                    > 0
            );
            for window in app.webview_windows().into_values() {
                window.destroy().unwrap();
            }
        }
    });
    assert_eq!(code, 0);
    let shared = handle.state::<shared_runtime_tauri::SharedRuntime>();
    let catalog = shared
        .runtime()
        .operation::<runtime_adapter_demo::Catalog>()
        .unwrap();
    let after = tauri::async_runtime::block_on(catalog.get(
        &shared_runtime::Caller::window("main"),
        (),
        Default::default(),
    ));
    assert!(matches!(
        after,
        Err(shared_runtime::CallError::ShuttingDown)
    ));
    assert_eq!(
        shared.runtime().stats().cache_weight_bytes(),
        0,
        "caches cleared"
    );
}
