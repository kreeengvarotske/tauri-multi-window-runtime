# Independent window-notes backend consumer

This package has its own workspace and Git-pinned dependency. It checks text
notes, per-window isolation, invalid-input errors, reopen cleanup and shutdown
through public exports. It is a backend integration check, not a second native
Tauri/WebView application or an IPC authorization test.

From the repository root, run `./tests/consumers/Test-WindowNotes.ps1 -Revision <full-SHA>`.
The script copies only the source and manifest to a new temporary directory,
pins the selected revision, generates and verifies its own lock, builds/runs
there and retains the evidence. Download caches may be reused. CI selects the
actual PR head or pushed commit, not the fixture's baseline preview dependency.

The 64-byte input validation occurs inside the operation. Real IPC commands
must bound bytes before decoding and derive caller identity from Tauri's
injected window; the labels here are trusted backend examples.
