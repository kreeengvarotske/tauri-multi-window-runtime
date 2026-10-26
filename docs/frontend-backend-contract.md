# Операции, которые нужны фронтенду от Rust Core

Статус: **интеграция v1 реализована в ветке `feat/frontend-integration`, ожидает локальной проверки и ревью.** Команды Tauri используют `crates/runtime-ipc`, который в свою очередь вызывает универсальное ядро `crates/runtime-core`.

Основа: черновик `docs/ipc-contract.md` v0.1 (PR #1). Этот документ не вводит новых команд, а раскладывает их по полям, которые нужны для интеграции: схемы, ошибки, изменяет ли операция состояние, права окон, этап. Если документы разойдутся, приоритет у `ipc-contract.md` после его согласования.

В коде контракт отражён в `src/lib/runtime/contract.ts`, вызовы делает только `src/lib/runtime/tauri/tauri-transport.ts`.

## Сводка

| Операция SDK | Команда Tauri | Изменяет состояние | Окна | Этап | В Rust | В SDK |
|---|---|---|---|---|---|---|
| `projects.getMetadata` | `runtime_get_project_metadata` | нет (заполняет кэш ядра как побочный эффект) | `main`, `secondary` | v1, обязательна | да | да (tauri + mock) |
| `diagnostics.getStats` | `runtime_get_debug_stats` | нет | `main`, `secondary` | v1, обязательна | да | да (tauri; в mock намеренно ошибка) |
| `cache.invalidateProject` | `runtime_invalidate_project` | да | только `main` | v1 | да | да (только TAURI) |
| `cache.clear` | `runtime_clear_cache` | да | только `main` | v1 | да | да (только TAURI) |
| `events.onCacheInvalidated` | событие `runtime://cache-invalidated` | — | все окна получают | v1 | да | да (tauri; в mock пустая подписка) |

Операции окон (создать и сфокусировать `secondary`) идут не через Core, а через встроенный API Tauri (`@tauri-apps/api/webviewWindow`, `src/lib/windows.ts`). Права на них выданы только окну `main` в `src-tauri/capabilities/window-management.json`. В контракт с ядром они не входят.

## Общие правила

- JSON в camelCase, аргументы команд тоже (`projectId`).
- Любая ошибка отклоняет Promise объектом `{ code: string, message: string }`. SDK превращает его в `RuntimeError` с тем же `code`; неизвестный `code` показывается как есть.
- Окно не передаёт свою метку, `windowId` или права. Ядро берёт контекст из `tauri::WebviewWindow` в обработчике. Метки `main` и `secondary` становятся частью контракта.
- SDK не кэширует, не объединяет запросы и не повторяет их. Каждый вызов UI доходит до `invoke`.
- Права на команды заданы через `tauri_build::AppManifest` и capabilities. Чтение доступно `main` и `secondary`; изменение кэша — только `main`. Обработчики дополнительно проверяют доверенную метку `WebviewWindow`, полученную от Tauri.

Коды, которые создаёт только SDK: `IPC_UNAVAILABLE` (страница не в Tauri), `COMMAND_NOT_FOUND` (команда не зарегистрирована), `UNKNOWN_ERROR` (непонятное отклонение), `STATS_UNAVAILABLE_IN_MOCK`, `CACHE_ADMIN_UNAVAILABLE_IN_MOCK`.

## 1. `runtime_get_project_metadata`

Метаданные проекта через `CachedService::run(projectId, …)`: кэш, затем объединение параллельных вызовов с тем же ключом из любых окон, затем запуск операции.

**Вход**

```ts
{ projectId: string } // после trim не пустой, не длиннее 128 символов
```

SDK проверяет это до вызова и сразу отвечает `INVALID_ARGUMENT`; ядро должно проверять то же самое, потому что SDK не единственный возможный клиент.

**Выход** `ProjectMetadata`

```ts
{
  projectId: string;    // эхо запрошенного id
  name: string;
  revision: number;     // u32 в Rust
  computedAtMs: number; // время вычисления; одинаковое значение = один общий результат
}
```

**Ошибки**

| `code` | Когда |
|---|---|
| `INVALID_ARGUMENT` | пустой или длинный `projectId` |
| `PROJECT_NOT_FOUND` | проекта нет |
| `ACCESS_DENIED` | окну запрещён доступ к проекту |
| `OPERATION_FAILED` | вычисление упало; ошибка не кэшируется |
| `INTERNAL` | всё остальное |

**Права:** все окна (`main`, `secondary`), разрешение `allow-runtime-get-project-metadata` в `capabilities/default.json`. В демо v1 проверка доступа к отдельным проектам не реализована; `ACCESS_DENIED` зарезервирован, а доступ к административным командам контролируется на уровне окна.

**Этап:** v1, без неё интеграция невозможна.

**Mock** (`src/lib/runtime/mock/`): задержка 150–400 мс, фикстуры `demo`, `project-42`, `main-only` (доступен только окну `main`), `broken` → `OPERATION_FAILED`, `forbidden` → `ACCESS_DENIED`, любой другой id → `PROJECT_NOT_FOUND`, регулируемая доля `OPERATION_FAILED`. У каждого ответа свой `computedAtMs`: mock ничего не объединяет. Это тестовые данные фронтенда, а не данные ядра.

## 2. `runtime_get_debug_stats`

Снимок счётчиков ядра для панели диагностики. Обновляется только вручную. Сам вызов в счётчики не входит.

**Вход:** нет.

**Выход** `RuntimeDebugStats`

```ts
{
  requestsReceived: number;   // вызовы getMetadata, прошедшие валидацию
  operationsExecuted: number; // реальные запуски вычисления
  coalescedRequests: number;  // присоединились к идущей операции
  cacheHits: number;          // ответ из кэша
  failedRequests: number;     // завершились ошибкой
  cachedEntries: number;      // CachedService::cached_entries()
  cachePolicy:
    | { kind: "noStore" }
    | { kind: "ttl"; ttlMs: number }
    | { kind: "forever" };
}
```

Инвариант, который UI проверяет и показывает: `requestsReceived = operationsExecuted + coalescedRequests + cacheHits`.

The invariant holds only while no request is in flight: `requestsReceived` is counted when a valid call enters `RuntimeIpc`, and the outcome counter when it completes (test `stats_disagree_while_a_request_is_in_flight` in `crates/runtime-ipc`). The counters are shared by all windows, so one window cannot tell another window's unfinished calls from a bug. The UI therefore reports a mismatch as "does not add up, refresh after every series has finished", not as a proven violation.

**Ошибки:** `INTERNAL`.

**Права:** все окна, `allow-runtime-get-debug-stats` в `capabilities/default.json`. Только диагностика, не используется как контроль доступа.

**Этап:** v1, нужна для демонстрации объединения запросов.

**Решено:** `runtime-ipc` вызывает `CachedService::run_with_metadata()` и обновляет счётчики по `outcome.kind`; ошибки считаются отдельно через `outcome.result`.

**Mock:** всегда `STATS_UNAVAILABLE_IN_MOCK`. Поддельные счётчики выглядели бы как данные ядра, поэтому их нет.

## 3. `cache.invalidateProject` / `runtime_invalidate_project`

Сбросить кэш одного проекта, чтобы показать повторное вычисление без ожидания TTL.

- Вход: `{ projectId: string }`. Выход: `{ invalidated: boolean }`.
- Ошибки: `INVALID_ARGUMENT`, `ACCESS_DENIED`, `INTERNAL`.
- Изменяет состояние кэша. Только окно `main`: разрешение `allow-runtime-invalidate-project` задано в `capabilities/runtime-main.json`, а обработчик Rust дополнительно проверяет метку вызвавшего `WebviewWindow`.
- Команда подключена к TypeScript SDK как `runtime.cache.invalidateProject({ projectId })`. В TAURI-режиме кнопка доступна только главному окну и автоматически обновляет статистику после операции.

## 4. `cache.clear` / `runtime_clear_cache`

Очистить весь кэш сервиса.

- Вход: нет. Выход: `null`.
- Ошибки: `ACCESS_DENIED`, `INTERNAL`.
- Изменяет состояние кэша. Только окно `main`: разрешение `allow-runtime-clear-cache` задано в `capabilities/runtime-main.json`, а обработчик Rust дополнительно проверяет метку вызвавшего `WebviewWindow`.
- Команда подключена к TypeScript SDK как `runtime.cache.clear()`. В TAURI-режиме кнопка доступна только главному окну и автоматически обновляет статистику после операции.

## 5. Событие `runtime://cache-invalidated` (v1)

Payload `{ projectId: string | null }` (`null` после `clear`), рассылается всем окнам из `runtime_invalidate_project` и `runtime_clear_cache` после изменения кэша (`src-tauri/src/commands.rs`). Ошибка рассылки не превращает команду в ошибку: кэш к этому моменту уже изменён. Только информирует: SDK сам ничего не перезапрашивает.

- SDK: `runtime.events.onCacheInvalidated(handler)` возвращает функцию отписки. Вне Tauri и в MOCK подписка ничего не делает.
- UI: каждое окно при событии обновляет статистику и показывает в таймере кэша, что результат сброшен.

Window events are not authenticated: with `core:default` every window may `emit`/`emitTo` any event, including `runtime://cache-invalidated` and the frontend-only `lab://run-series`. They are hints, never a source of data or rights. The UI only re-requests stats on `runtime://cache-invalidated`, and the secondary window starts a series from `lab://run-series` only when the payload is a string `projectId` and one of the series sizes the UI offers (1, 10, 20, 50); anything else is ignored. A `lab://run-series` that arrives while a series is still running in that window is ignored too, because a valid payload bounds one request but not how often it is sent. A malformed `runtime://cache-invalidated` payload (anything other than `{ projectId: string | null }`) does not touch the cache timer; stats are still re-read from Core. A well-formed forged payload can still mislead the cache timer until the next stats refresh: events carry no sender identity, and removing `allow-emit*` from the secondary window (C-3 in #13) is a separate capability decision.


## Rust demo-provider fixtures (not the frontend mock)

The real Rust provider used by Tauri accepts these IDs in v1:
- `demo` → Demo project, revision 3;
- `project-42` → Project 42, revision 7 (the frontend's initial selection);
- `alpha` → Alpha project, revision 1;
- `beta` → Beta project, revision 2;
- `missing` (and any unknown ID) → `PROJECT_NOT_FOUND`;
- `flaky` → `OPERATION_FAILED` on every execution; errors are not cached.

The mock-only `main-only` and `forbidden` fixtures simulate project-level authorization states in the frontend tests; the Rust demo v1 does not implement project-level authorization. The Rust `ACCESS_DENIED` path currently protects cache administration commands invoked from a window other than `main`.

## Статус интеграции v1

- [x] `runtime_get_project_metadata` зарегистрирована в Tauri и обращается к `RuntimeIpc`.
- [x] `runtime_get_debug_stats` зарегистрирована в Tauri; чтение статистики само не считается запросом.
- [x] `runtime_invalidate_project` и `runtime_clear_cache` доступны только окну `main` через capabilities и дополнительную проверку `WebviewWindow::label()`.
- [x] `runtime-core` остаётся без зависимостей от Tauri и serde.
- [x] Прогнаны frontend-проверки: build, typecheck и 60 Vitest-тестов; Cargo fmt, 40 Rust-тестов и Clippy с `--locked`.
- [x] Запущено `npm.cmd run tauri dev`; вручную проверены main/secondary, coalescing, кэш, общая статистика, ошибки и валидация входа.
- [x] UI-контролы инвалидации проекта и очистки общего кэша подключены к SDK (видны только в главном TAURI-окне).
- [ ] Повторно прогнать frontend и Cargo-проверки после добавления управления кэшем.
- [ ] Вручную проверить кнопки инвалидации/очистки и убедиться, что secondary не имеет административных capabilities.
