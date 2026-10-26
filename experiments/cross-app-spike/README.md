# cross-app-spike (non-normative)

A vertical prototype for [the cross-app design](../../docs/cross-app/README.md): one broker process and independently launched client processes, through a typed, versioned protocol over a per-user local endpoint (a named pipe on Windows, a Unix socket on Linux). It reuses `runtime-core` **unchanged**, with key `(Scope, Params)`.

**This is a spike.** The identity check (`src/identity.rs`) is provisional and is not a Group 1 decision (Q1). Only synthetic data is used. It is its own Cargo workspace, so it does not touch the root workspace or `Cargo.lock`.

```text
src/protocol.rs   messages, error codes, version negotiation (strict JSON)
src/frame.rs      u32-LE length-prefixed frames, 1 MiB cap
src/transport.rs  per-user endpoint (Windows: owner-only DACL), single instance, peer pid and user (uid / SID)
src/identity.rs   manifest + OS evidence (pid → executable, same user)
src/ops.rs        typed synthetic operations (Public checksum, App note, failing op)
src/broker.rs     handshake, grants, scope derivation, CachedService per op, notices
src/client.rs     typed client, cancellation, late-reply drop, reconnecting Session
src/bin/          spike-broker, spike-client (a headless "test application")
tests/cross_process.rs  12 tests with real separate processes
```

## Run

```sh
cd experiments/cross-app-spike
cargo test --locked                 # unit + cross-process tests
cargo clippy --all-targets --locked -- -D warnings
```

By hand (Linux; on Windows use `--endpoint \\.\pipe\tmwr-spike-demo`):

```sh
cargo build
cp target/debug/spike-client /tmp/alpha-client
cat > /tmp/manifest.json <<JSON
{"apps":[{"appId":"demo.alpha","executable":"/tmp/alpha-client","grants":["fixture.checksum@1"]}]}
JSON
mkdir -m 700 -p /tmp/spike && target/debug/spike-broker --endpoint /tmp/spike/b.sock --manifest /tmp/manifest.json &
/tmp/alpha-client --endpoint /tmp/spike/b.sock --app-id demo.alpha checksum 7 1024 2
```

`--op-delay-ms` exists only to make overlap deterministic in tests. It is not a workload, and no timing, CPU or memory conclusion may be drawn from this spike.
