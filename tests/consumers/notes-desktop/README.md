# Independent desktop notes consumer

This is a second real Tauri application, separate from the catalog demo. It
uses public Git dependencies, a separate workspace and its own lock. A local
WebView exercises two cached note requests, invalid lengths and a forged caller
field. Rust derives identity from the injected window, bounds request/response
bytes, and checks cache cleanup plus refusal of calls on application exit.

Install PowerShell 7 or newer (`pwsh`). From the repository root run:

```powershell
pwsh -NoProfile -File ./tests/consumers/Test-WindowNotes.ps1 -Revision <full-SHA> -Desktop
```

The harness creates a fresh external project/target/profile, verifies all three
runtime Git identities and retains its native report. Linux requires Tauri
system dependencies and Xvfb. The desktop has a generated command manifest and
window-specific capabilities; it uses no frontend bundler or npm packages.
The `finish` command exists only in this qualification application.
The test-only `qualification` command reports the CLI-selected soak duration.
An optional second positional argument to the executable selects 0–600 seconds;
zero keeps CI fast, while native release qualification records its bounded soak.

Notes are limited to 64 UTF-8 bytes. Request and response budgets are 512 bytes
so even 64 control characters fit after JSON escaping. The native page checks
that boundary as well as ordinary text and a cache hit.

The harness establishes functional behavior and a bounded application wait.
Its Windows Start-Process launcher alone does not prove complete process-tree
cleanup. Stable-release native qualification additionally uses an owned Job
Object and reconciles its completion messages and process accounting.

The initial Debug run passed all assertions and strict owned-Job cleanup while
emitting Chromium's unregister-class diagnostic 1412. Its cause was not proven;
logs are retained and Release behavior is checked separately. Older upstream
[Tauri discussion](https://github.com/orgs/tauri-apps/discussions/3555) documents
similar exit diagnostics, but does not establish this run's cause.
