# 04. API specification: protocol v1 (spike), scopes, cache and version rules

This is the interface `experiments/cross-app-spike` implements (`src/protocol.rs`, `src/ops.rs`, `src/client.rs`). It is a **proposal**. It is new, and it does not change any existing Tauri command, DTO, event or capability. The Runtime Lab contract (`docs/frontend-backend-contract.md`) is untouched.

## 1. Transport and framing

| Item | Rule |
|---|---|
| Endpoint | Windows: named pipe `\\.\pipe\<name>`, created with `FIRST_PIPE_INSTANCE` and rejecting remote clients. Linux: Unix socket in a `0700` directory owned by the user, socket `0600`, plus an exclusive lock file. **No TCP.** |
| Frame | `u32` little-endian byte length, then one UTF-8 JSON document. Max 1 MiB in either direction, checked **before** allocating |
| Encoding | JSON with `camelCase` fields and a `type` tag. Every message and params type is `deny_unknown_fields` |
| Order | The first client frame must be `hello`, within 5 s. A second `hello`, a malformed frame or an oversized frame ⇒ `reject` and close |

## 2. Messages

Client → broker:

```jsonc
{"type":"hello","protocolMin":1,"protocolMax":1,"sdk":"cross-app-spike/0.0.0","appId":"demo.alpha"} // appId is a CLAIM
{"type":"call","id":1,"op":"fixture.checksum","opVersion":1,"params":{"seed":7,"sizeKib":1024},"deadlineMs":5000}
{"type":"cancel","id":1}
{"type":"invalidate","id":2,"op":"fixture.checksum","opVersion":1,"params":{"seed":7,"sizeKib":1024}}
{"type":"stats","id":3}
```

Broker → client:

```jsonc
{"type":"welcome","protocol":1,"brokerVersion":"0.0.0","instanceId":"9f…","appId":"demo.alpha",
 "maxFrameBytes":1048576,"maxInFlight":32,"operations":[{"name":"fixture.checksum","version":1,"scope":"public"}]}
{"type":"reject","code":"identityMismatch","message":"…"}                  // then close
{"type":"result","id":1,"kind":"executed|coalesced|cacheHit","value":{…}}
{"type":"error","id":1,"code":"invalidParams","message":"…","retryable":false}
{"type":"notice","event":{"kind":"invalidated","op":"fixture.checksum","opVersion":1,"scope":"public"}}
```

- `id` is chosen by the client and unique among its in-flight calls (`duplicateId` otherwise). Replies can arrive in any order.
- `welcome.operations` lists **only the operations this client is granted**, so the catalogue itself is not a cross-app disclosure.
- `welcome.appId` is the identity the broker verified. The client must use it, not its own claim.

## 3. Typed client API (Rust)

```rust
let client = Client::connect(&endpoint, "demo.alpha").await?;          // handshake + server uid check
let ok = client.call::<Checksum>(&ChecksumParams { seed: 7, size_kib: 1024 }).await?;
// ok.kind: Executed | Coalesced | CacheHit;  ok.value: ChecksumOutput
let call = client.start::<Checksum>(&params, Some(Duration::from_secs(5))).await?;
client.cancel(call.id).await?;                                          // late reply is dropped
let mut session = Session::new(endpoint, "demo.alpha");                 // reconnect + retry
session.call::<Checksum>(&params, 20).await?;                           // only for idempotent ops
```

Operations are types implementing `Operation { NAME, VERSION, SCOPE, Params, Output }`, shared by the client and the broker. A Tauri app would expose them to its WebView through its **own** commands. The WebView never sees the broker.

## 4. Scope, cache and coalescing rules

1. **Scope is derived, never sent.** `Public` for `SCOPE = Public`; `App(verified appId)` for `SCOPE = App`. No message has a scope field, and extra fields are rejected.
2. **Key = `(Scope, Params)`** for both the cache and the coalescer, via `runtime_core::CachedService` unchanged. `Params` are typed and strict, so two keys are equal exactly when the semantic requests are equal.
3. An operation is admitted to the registry only if its output is a **deterministic function of `(Scope, Params, operation version)`**, over data that is acceptable to disclose to its scope (see [03 §4](03-threat-model.md#4-residual-risk)). Anything that depends on the user, an account, a session, time or the network is not admitted.
4. Cache policy per operation: `NoStore | Ttl(d) | Forever`. TTL counts from insertion. Errors are never cached. Results never cross broker instances.
5. **Invalidation** is scoped like a call and needs an `invalidate:op@v` grant. It never cancels in-flight work, and in-flight work cannot repopulate the cache after it (Core V2).
6. **Notices** carry `op`, `opVersion` and `scope` only. They go to connections that can read that scope and hold the op grant, and they may be dropped (best effort).
7. **Cancellation** aborts only the caller's task. Remaining waiters keep the operation (re-run per Core V3). The client never delivers a reply for an id it has cancelled or abandoned.
8. **Deadlines**: `deadlineMs` is capped by the broker (30 s in the spike). On expiry the result is `timeout` (retryable).

## 5. Error codes

| Code | Meaning | Retry? |
|---|---|---|
| `helloRequired` | First frame was not a hello, or it timed out | no (protocol bug) |
| `versionMismatch` | No common protocol version | no: fall back |
| `notRegistered` | `appId` not in the manifest | no |
| `identityMismatch` | OS evidence does not match the registration | no |
| `unknownOperation` | `op@version` not offered | no: SDK too new or too old |
| `notPermitted` | No grant for the call, invalidation or stats | no |
| `invalidParams` | Strict decoding or bounds failed; nothing executed | no |
| `duplicateId` | `id` already in flight on this connection | no (client bug) |
| `busy` | `maxInFlight` reached | **yes**, with backoff |
| `frameTooLarge` / `malformedFrame` | Framing violation; connection closed | no |
| `operationFailed` | The operation returned an error (not cached) | caller's choice |
| `timeout` | Deadline passed | **yes** |
| `brokerUnavailable` | Client-side: no broker or connection lost | **yes**: reconnect, re-handshake |

## 6. Version rules

- **Protocol version** (`u16`). The broker supports a contiguous range. The client sends its range, the broker picks the highest common version or rejects. Adding an *optional* message field is not a version bump only if both sides accept it, and `deny_unknown_fields` means they do not. So in this design **every wire change is a protocol bump**. That is deliberate: no silent misreads (T-18).
- **Operation version** (`op@v`). A change to params, output or semantics is a new `v`. The broker keeps `v` and `v−1` for at least one release. Cache keys are per `op@v`, so versions never share entries.
- **SDK/broker compatibility** is decided only by these two numbers, never by `brokerVersion` strings.
- **Deprecation**: `welcome` may later list deprecated operations [design]. Removal requires a protocol bump if message shapes change.

## 7. Client registration (spike manifest)

```json
{ "apps": [
  { "appId": "demo.alpha", "executable": "C:\\Program Files\\Alpha\\alpha.exe",
    "grants": ["fixture.checksum@1", "fixture.appNote@1", "invalidate:fixture.appNote@1"] } ] }
```

Who writes this file, where it lives and how it is protected is **open (Q2)**. The spike reads it from a path given on the command line, and the tests generate it.
