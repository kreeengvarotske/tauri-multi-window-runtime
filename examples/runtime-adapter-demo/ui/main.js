// Adapter commands take the request as UTF-8 JSON bytes and answer with
// JSON bytes; errors arrive as { code, message }.
const { invoke } = window.__TAURI__.core;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function call(command, request) {
  const body = request === undefined ? undefined : encoder.encode(JSON.stringify(request));
  const bytes = await invoke(command, body);
  return JSON.parse(decoder.decode(bytes));
}

const out = document.querySelector("#out");
const show = (value) => (out.textContent = JSON.stringify(value, null, 2));
document.querySelector("#page").onclick = () => call("demo_catalog_page", { offset: 0, limit: 10 }).then(show, show);
document.querySelector("#note").onclick = () => call("demo_window_note").then(show, show);

// `--self-test` opens w1 with ?self-test: run the commands over the real
// IPC and report the outcomes to Rust.
async function selfTest() {
  const outcome = async (promise) => {
    try {
      return { ok: await promise };
    } catch (error) {
      return { error };
    }
  };
  const results = {
    page: await outcome(call("demo_catalog_page", { offset: 5, limit: 2 })),
    oversized: await outcome(invoke("demo_catalog_page", encoder.encode(JSON.stringify({ offset: 0, limit: 1 }) + " ".repeat(300)))),
    forged: await outcome(call("demo_catalog_page", { offset: 0, limit: 1, window: "main" })),
    note: await outcome(call("demo_window_note")),
    stats: await outcome(call("demo_stats")),
  };
  await window.__TAURI__.event.emit("demo://self-test", results);
}

if (new URLSearchParams(location.search).has("self-test")) {
  selfTest();
}
