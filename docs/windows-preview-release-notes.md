# Windows developer preview

Draft release notes. Set the release version and source revision after the preview stack is integrated and verified.

This preview adds a Rust runtime for sharing application data and work between windows in one Tauri v2 application. For example, two catalog windows can read bounded pages from one Rust catalog. The application decides which views to expose and which windows may call them.

## What is included

- Shared and per-window operation scopes with configurable cache and concurrency limits.
- Typed Tauri commands for bounded responses, using caller identity supplied by the window. Command access is controlled through Tauri capabilities.
- Window-state cleanup on close, runtime shutdown on exit, and fixed IPC error messages that avoid sending internal error details to the WebView.
- A runnable two-window example and a [Windows quick start](../examples/runtime-adapter-demo/README.md) with instructions for a separate Tauri project.

## Preview scope

The verified setup is Windows with Tauri v2 and WebView2. The quick start pins the Git source revision for both runtime crates. The build environment needs read access to that repository. The [preview review record](windows-preview-review.md) tracks the tested toolchain and the checks required for the final revision.

This release covers sharing inside a single application. Cross-application sharing is a separate experiment. End-to-end memory and CPU results will be reported after the benchmark protocol has been completed.
