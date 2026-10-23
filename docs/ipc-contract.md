# Контракт Tauri IPC между Runtime Core и TypeScript SDK

Статус: **черновик v0.2, на согласовании**. Сверено с веткой `feat/runtime-core` (коммит `0c97a7f`, 29 тестов проходят).

Документ фиксирует, что фронтенд может вызвать у ядра, в каком виде приходят ответы и ошибки, и где в Rust живёт связка с Tauri. Пока контракт не согласован, фронтенд работает через mock-транспорт и не вызывает `invoke` напрямую из UI.

## 1. Принципы

1. **Дедупликация и кэш только в ядре.** SDK не кэширует, не объединяет запросы и не делает ретраи. Иначе демо не доказывает работу `TaskCoalescer` и `CachedService`.
2. **Ядро не знает про Tauri.** `crates/runtime-core` остаётся без зависимостей от `tauri` и `serde`. Связка (DTO, маппинг ошибок, команды) лежит отдельным слоем, `lib.rs` ядра не меняется.
3. **Фронтенд не управляет политикой кэша.** `CachePolicy` задаётся в Rust при создании сервиса. Наружу она отдаётся только на чтение, в статистике.
4. **Контекст окна берёт Rust.** Команды получают `tauri::WebviewWindow` параметром обработчика. JS не передаёт `windowId`, `moduleId` и подобное.
5. **JSON в camelCase.** Все DTO помечены `#[serde(rename_all = "camelCase")]`. Аргументы команд Tauri v2 и так принимает в camelCase (`project_id` в Rust = `projectId` в JS), `rename_all = "snake_case"` на командах не используется.
6. **Числа помещаются в JS.** Счётчики и миллисекунды не превышают `Number.MAX_SAFE_INTEGER` (2^53 − 1). В Rust они `u64`, при сериализации значения выше предела насыщаются до него.

## 2. Команды

| Команда | Аргументы | Ответ | Кто может вызывать | Этап |
|---|---|---|---|---|
| `runtime_get_project_metadata` | `{ projectId: string }` | `ProjectMetadata` | все окна | v1 |
| `runtime_get_debug_stats` | нет | `RuntimeDebugStats` | все окна | v1 |
| `runtime_invalidate_project` | `{ projectId: string }` | `{ invalidated: boolean }` | только `main` | v1.1, предложение |
| `runtime_clear_cache` | нет | `null` | только `main` | v1.1, предложение |

### 2.1 `runtime_get_project_metadata`

Проходит через `CachedService<String, ProjectMetadata, CoreError>::run(projectId, …)`:

- значение в кэше и не истекло: ответ сразу, без запуска операции;
- параллельные вызовы с тем же `projectId` (из любого окна) получают результат одной операции;
- ошибки не кэшируются: следующий вызов запускает операцию заново.

Валидация до обращения к сервису: `projectId` после `trim` не пустой и не длиннее 128 символов, иначе `INVALID_ARGUMENT`. Пустая строка не должна попадать в кэш как ключ.

### 2.2 `runtime_get_debug_stats`

Возвращает снимок счётчиков. Сам вызов статистики в счётчики **не** входит. Обновление в UI только ручное, без поллинга.

### 2.3 `runtime_invalidate_project` и `runtime_clear_cache` (v1.1)

Обёртки над `CachedService::invalidate` и `CachedService::clear`. Нужны демо, чтобы показать повторное вычисление после инвалидации, не дожидаясь TTL. Разрешены только окну `main` через capabilities (см. раздел 6).

Важно для UI: `invalidate` в ядре увеличивает **общее** поколение сервиса. Операции, уже идущие по любым ключам, вернут результат своим вызывающим, но не попадут в кэш. Это поведение ядра, контракт его не меняет, но в UI это надо подписать, чтобы не выглядело багом.

## 3. Типы данных

### 3.1 `ProjectMetadata`

```json
{
  "projectId": "demo",
  "name": "Demo project",
  "revision": 3,
  "computedAtMs": 1761210000000
}
```

| Поле | Rust | TS | Смысл |
|---|---|---|---|
| `projectId` | `String` | `string` | эхо запрошенного id |
| `name` | `String` | `string` | отображаемое имя |
| `revision` | `u32` | `number` | версия метаданных |
| `computedAtMs` | `u64` | `number` | Unix-время вычисления в мс. Одинаковое значение у двух ответов = один и тот же результат (из кэша или объединённый) |

`computedAtMs` даёт UI простой способ увидеть объединение и кэш без отдельного поля «откуда пришёл ответ».

### 3.2 `RuntimeDebugStats`

```json
{
  "requestsReceived": 50,
  "operationsExecuted": 1,
  "coalescedRequests": 49,
  "cacheHits": 0,
  "failedRequests": 0,
  "cachedEntries": 1,
  "cachePolicy": { "kind": "ttl", "ttlMs": 30000 }
}
```

| Поле | Смысл |
|---|---|
| `requestsReceived` | вызовы `runtime_get_project_metadata`, прошедшие валидацию |
| `operationsExecuted` | сколько раз реально запускалась операция вычисления |
| `coalescedRequests` | вызовы, присоединившиеся к уже идущей операции |
| `cacheHits` | вызовы, получившие значение из кэша без операции |
| `failedRequests` | вызовы, завершившиеся ошибкой (включая присоединившиеся к упавшей операции) |
| `cachedEntries` | `CachedService::cached_entries()` на момент снимка |
| `cachePolicy` | политика сервиса, см. 3.3 |

Инвариант для проверки в тестах и в UI: `requestsReceived = operationsExecuted + coalescedRequests + cacheHits`. Отменённые вызовы в IPC не встречаются, потому что `invoke` из JS не отменяется.

**Откуда берутся счётчики.** Слой IPC вызывает `CachedService::run_with_metadata` (добавлен в `0c97a7f`) и сам ведёт счётчики на `AtomicU64`:

```rust
stats.requests_received.fetch_add(1, Relaxed); // после валидации
let outcome = service.run_with_metadata(project_id, load).await;
match outcome.kind {
    ServiceRunKind::CacheHit => stats.cache_hits.fetch_add(1, Relaxed),
    ServiceRunKind::Coalesced => stats.coalesced_requests.fetch_add(1, Relaxed),
    ServiceRunKind::Executed => stats.operations_executed.fetch_add(1, Relaxed),
};
if outcome.result.is_err() {
    stats.failed_requests.fetch_add(1, Relaxed);
}
```

Ядро счётчиков не хранит, оно только сообщает исход вызова. Так ядро остаётся без знания о статистике демо.

### 3.3 Сериализация `CachePolicy`

Внутренний тег `kind`, длительность в миллисекундах:

```json
{ "kind": "noStore" }
{ "kind": "ttl", "ttlMs": 30000 }
{ "kind": "forever" }
```

Сериализует DTO в слое IPC, а не сам `CachePolicy`, чтобы ядро не зависело от `serde`:

```rust
#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CachePolicyDto {
    NoStore,
    #[serde(rename_all = "camelCase")]
    Ttl { ttl_ms: u64 },
    Forever,
}

impl From<CachePolicy> for CachePolicyDto {
    fn from(policy: CachePolicy) -> Self {
        match policy {
            CachePolicy::NoStore => Self::NoStore,
            CachePolicy::Ttl(ttl) => Self::Ttl {
                ttl_ms: u64::try_from(ttl.as_millis())
                    .unwrap_or(u64::MAX)
                    .min(MAX_SAFE_INTEGER),
            },
            CachePolicy::Forever => Self::Forever,
        }
    }
}
```

Миллисекунды выбраны потому, что `Duration` в serde по умолчанию даёт `{ secs, nanos }`, а это неудобно в JS. Субмиллисекундные TTL округляются вниз (`Ttl(500µs)` показывается как `ttlMs: 0`); для отображения этого достаточно. Обратное преобразование (из JSON в `CachePolicy`) не нужно, пока политика не приходит с фронтенда.

## 4. Ошибки

Любая команда отклоняет Promise объектом:

```json
{ "code": "PROJECT_NOT_FOUND", "message": "Project 'missing' not found" }
```

| `code` | Когда | Источник |
|---|---|---|
| `INVALID_ARGUMENT` | пустой или слишком длинный `projectId` | IPC |
| `PROJECT_NOT_FOUND` | проекта нет | ядро |
| `ACCESS_DENIED` | окну запрещён доступ к проекту | ядро / IPC |
| `OPERATION_FAILED` | операция вычисления упала (сеть, диск и т.п.) | ядро |
| `INTERNAL` | всё остальное, включая паники в обработчике | IPC |

Правила:

- `message` читаем человеком и не содержит путей файловой системы и секретов;
- новые коды добавляются только с согласованием, SDK любой неизвестный `code` показывает как есть, не падая;
- `Arc<E>` из `CachedService::run` в слое IPC превращается в `IpcError` через `From<&CoreError>` (без клонирования `E`), чтобы обработчик Tauri возвращал владеющий сериализуемый тип.

```rust
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcError {
    pub code: IpcErrorCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum IpcErrorCode {
    InvalidArgument,
    ProjectNotFound,
    AccessDenied,
    OperationFailed,
    Internal,
}
```

Коды, которые создаёт только SDK (Rust их не отправляет):

| `code` | Когда |
|---|---|
| `IPC_UNAVAILABLE` | страница открыта в обычном браузере, `window.__TAURI_INTERNALS__` нет |
| `COMMAND_NOT_FOUND` | Tauri отклонил строкой вида `command … not found` (ядро не зарегистрировало команду) |
| `UNKNOWN_ERROR` | отклонение не похоже ни на `IpcError`, ни на известную строку |
| `STATS_UNAVAILABLE_IN_MOCK` | статистика запрошена в mock-режиме |

## 5. События

В v1 событий нет: UI обновляет статистику вручную.

Предложение для v1.1, вместе с командами инвалидации:

| Событие | Payload | Кому |
|---|---|---|
| `runtime://cache-invalidated` | `{ projectId: string \| null }` (`null` = `clear`) | всем окнам через `app.emit` |

Чтобы второе окно знало, что его последние данные устарели. Событие только информирует, SDK сам по нему ничего не перезапрашивает.

## 6. Где живёт код и права доступа

```
crates/runtime-core/        ядро, без tauri и serde (не трогаем)
crates/runtime-ipc/         DTO, CachePolicyDto, IpcError, маппинг, счётчики; зависит от serde и runtime-core; без tauri
src-tauri/src/commands.rs   тонкие #[tauri::command], State<RuntimeState>, регистрация в invoke_handler
```

`runtime-ipc` без `tauri` можно тестировать обычным `cargo test`: в том числе снимки JSON для каждого DTO и ошибки, чтобы форма ответа не менялась незаметно.

Права (Tauri v2): команды объявляются через `tauri_build::Attributes::new().app_manifest(AppManifest::new().commands(&[...]))` в `build.rs`. Тогда в capabilities:

- `default.json` (`main`, `secondary`): `allow-runtime-get-project-metadata`, `allow-runtime-get-debug-stats`;
- `main-window.json` (`main`): плюс `allow-runtime-invalidate-project`, `allow-runtime-clear-cache` (v1.1).

Метки окон `main` и `secondary` становятся частью контракта.

## 7. TypeScript SDK

Типы для `src/lib/runtime/types.ts`:

```ts
export type CachePolicy =
  | { kind: "noStore" }
  | { kind: "ttl"; ttlMs: number }
  | { kind: "forever" };

export interface ProjectMetadata {
  projectId: string;
  name: string;
  revision: number;
  computedAtMs: number;
}

export interface RuntimeDebugStats {
  requestsReceived: number;
  operationsExecuted: number;
  coalescedRequests: number;
  cacheHits: number;
  failedRequests: number;
  cachedEntries: number;
  cachePolicy: CachePolicy;
}

export type CoreErrorCode =
  | "INVALID_ARGUMENT"
  | "PROJECT_NOT_FOUND"
  | "ACCESS_DENIED"
  | "OPERATION_FAILED"
  | "INTERNAL";

export type ClientErrorCode =
  | "IPC_UNAVAILABLE"
  | "COMMAND_NOT_FOUND"
  | "UNKNOWN_ERROR"
  | "STATS_UNAVAILABLE_IN_MOCK";

/** Неизвестные коды от ядра сохраняются как строка. */
export type RuntimeErrorCode = CoreErrorCode | ClientErrorCode | (string & {});

export interface IpcErrorPayload {
  code: string;
  message: string;
}

export interface CacheInvalidatedEvent {
  projectId: string | null;
}

export const RUNTIME_COMMANDS = {
  getProjectMetadata: "runtime_get_project_metadata",
  getDebugStats: "runtime_get_debug_stats",
  invalidateProject: "runtime_invalidate_project",
  clearCache: "runtime_clear_cache",
} as const;

export const RUNTIME_EVENTS = {
  cacheInvalidated: "runtime://cache-invalidated",
} as const;
```

Нормализация в `client.ts`: если отклонение является объектом со строковыми `code` и `message`, это `IpcErrorPayload`; если строка содержит `not found` и имя команды, это `COMMAND_NOT_FOUND`; иначе `UNKNOWN_ERROR` с исходным значением в `cause`.

## 8. Вопросы к владельцу ядра: разбор

Сводка: для v1 **новый код в ядре больше не нужен**. От владельца ядра нужны решения по пунктам 2, 3, 5, 6, 7 и 8, плюс `cargo fmt` (пункт 1). Всё остальное делается в слое IPC.

| № | Вопрос | Статус | Нужно от ядра |
|---|---|---|---|
| 1 | Исход вызова для статистики | закрыт `0c97a7f` | только `cargo fmt` |
| 2 | Тип ошибки и источник метаданных | нужно решение | ничего, если принять рекомендацию |
| 3 | Политика кэша для демо | нужно решение | ничего |
| 4 | Задержка операции | решено в IPC | ничего |
| 5 | Инвалидация в v1 или позже | нужно решение | ничего |
| 6 | Раскладка крейтов и workspace | нужно решение | согласие на корневой `Cargo.toml` |
| 7 | Тестовые данные и `ACCESS_DENIED` | нужно решение | ничего, если принять рекомендацию |
| 8 | Порядок слияния веток | нужно решение | влить `feat/runtime-core` в `main` или разрешить ветвиться от неё |

### 8.1 Исход вызова: закрыт

`run_with_metadata()` с `ServiceRunKind::{CacheHit, Coalesced, Executed}` **достаточно** для всех счётчиков из 3.2. Проверено на `0c97a7f`: 29 тестов проходят, `cargo clippy --all-targets` без предупреждений, `reports_coalesced_for_concurrent_request` 30 запусков подряд без падений.

Как ведёт себя API в пограничных случаях (это нужно знать UI, менять ничего не надо):

- **Отмена инициатора.** Если вызов, начавший операцию, отменён, оставшийся ожидающий запускает её заново и получает `Executed`. Обе попытки считаются в `operationsExecuted`, инвариант `requestsReceived = operationsExecuted + coalescedRequests + cacheHits` сохраняется. Через IPC это почти не случается: `invoke` из JS не отменяется.
- **Ошибка операции.** Инициатор получает `Executed`, присоединившиеся получают `Coalesced`, у всех `result` с ошибкой. Поэтому `failedRequests` считается отдельно по `result`, а не по `kind`.
- **Присоединение к только что завершённой операции.** Запись в `TaskCoalescer` живёт, пока её держит хотя бы один вызывающий. Вызов, пришедший в этот короткий промежуток, получает готовый результат с `Coalesced`. При `NoStore` это единственный путь, где «объединение» не означает настоящего перекрытия во времени. Для демо это допустимо.

Замечание по оформлению: `cargo fmt --check` даёт 17 расхождений, в основном `run` и `run_with_kind` в `lib.rs` без отступа внутри `impl` и пустая первая строка в `service.rs`. Предлагаю прогнать `cargo fmt` в `feat/runtime-core` и проверять его в CI.

### 8.2 Тип ошибки и источник метаданных

В ядре сейчас нет ни `ProjectMetadata`, ни операции, которая её загружает: `CachedService` обобщён по `V` и `E`. Значит, кто-то должен написать «демо-провайдер».

**Рекомендация:** провайдер и `enum ProjectError { NotFound, AccessDenied, Failed(String) }` живут в `crates/runtime-ipc`, а не в ядре. Ядро остаётся универсальным механизмом без предметной области. Маппинг в коды из раздела 4 делается там же.

Нужно решить: согласен ли владелец ядра, что предметные типы демо не входят в `runtime-core`.

### 8.3 Политика кэша для демо

**Рекомендация:** `CachePolicy::Ttl(Duration::from_secs(30))` для сервиса метаданных.

- `Forever`: после первой серии все запросы становятся `CacheHit`, объединение больше не увидеть без кнопки инвалидации.
- `NoStore`: виден только coalescing, кэш не демонстрируется.
- `Ttl(30 с)`: первая серия показывает объединение, повторная в течение 30 с показывает кэш, после истечения снова объединение.

Политика задаётся одним константным значением при создании `RuntimeState`, в контракте она только читается (`cachePolicy` в статистике). Изменений в ядре не требуется.

### 8.4 Задержка операции

Решается в демо-провайдере: `tokio::time::sleep(Duration::from_millis(400))` перед ответом. 50 вызовов из одной серии создаются в одном тике JS и гарантированно перекрываются. Фича `time` у `tokio` в ядре уже включена, а Tauri выполняет async-команды на своём tokio-рантайме, поэтому `CachedService` работает внутри команд без изменений.

### 8.5 Инвалидация в v1 или позже

`CachedService::invalidate` и `clear` уже есть, обёртки в IPC занимают по несколько строк.

**Рекомендация:** команды `runtime_invalidate_project` и `runtime_clear_cache` включить в v1 (только для окна `main`), событие `runtime://cache-invalidated` оставить на v1.1. Без инвалидации при TTL 30 с демо приходится ждать, чтобы повторить сценарий объединения.

Нужно решить: согласен ли владелец ядра расширить v1.

### 8.6 Раскладка крейтов и workspace

Сейчас `crates/runtime-core` самостоятельный пакет со своим `Cargo.lock` и `.gitignore`, корневого `Cargo.toml` нет, каркаса Tauri в `main` тоже нет. Для `crates/runtime-ipc` и `src-tauri` нужен общий workspace, иначе у каждого крейта будет свой `Cargo.lock` и своя папка `target`.

**Рекомендация:**

```toml
# Cargo.toml в корне
[workspace]
resolver = "3"
members = ["crates/runtime-core", "crates/runtime-ipc", "src-tauri"]
```

Плюс перенос `Cargo.lock` в корень и `/target` в корневой `.gitignore`. Это меняет структуру, которую создал владелец ядра, поэтому нужно его согласие.

Кто пишет код: предлагаю, чтобы `crates/runtime-ipc` и `src-tauri/src/commands.rs` писала сторона Maxim, а владелец ядра делал ревью. Ядро при этом не меняется. Также `edition = "2024"` требует Rust 1.85+, это стоит записать в README.

### 8.7 Тестовые данные и `ACCESS_DENIED`

**Рекомендация** для демо-провайдера:

| `projectId` | Ответ |
|---|---|
| `demo`, `alpha`, `beta` | успешные метаданные |
| `missing` | `PROJECT_NOT_FOUND` |
| `flaky` | всегда `OPERATION_FAILED` (ошибки не кэшируются, поэтому каждая серия снова выполняет операцию) |

Проверки доступа по окну в ядре нет. Если её добавлять, проверять доступ надо **до** вызова `CachedService`, а не внутри операции. Иначе кэш придётся делить по окнам (ключ `(scope, projectId)`), и объединение между окнами, ради которого демо и существует, пропадёт.

**Рекомендация для v1:** `ACCESS_DENIED` оставить в списке кодов как зарезервированный, но не реализовывать.

### 8.8 Порядок слияния веток

`crates/runtime-ipc` зависит от `runtime-core`, а в `main` ядра пока нет. Варианты:

1. Владелец ядра вливает `feat/runtime-core` в `main` после `cargo fmt`, ветка IPC ответвляется от `main`. **Рекомендую.**
2. Ветка IPC ответвляется от `feat/runtime-core` и вливается после неё.

Нужно решить, какой вариант выбрать и когда ядро будет готово к слиянию.
