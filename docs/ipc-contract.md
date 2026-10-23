# Контракт Tauri IPC между Runtime Core и TypeScript SDK

Статус: **черновик v0.1, на согласовании**. Сверено с веткой `feat/runtime-core` (коммит `356d571`, 26 тестов проходят).

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

**Чего нет в ядре сейчас:** `CachedService::run` не сообщает, был ли вызов попаданием в кэш, присоединением или запуском. Слой IPC может сам посчитать `requestsReceived` и `operationsExecuted` (флагом внутри замыкания), но отличить `cacheHits` от `coalescedRequests` снаружи нельзя. Нужна небольшая доработка ядра, см. вопрос 1 в разделе 8.

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

## 8. Вопросы к владельцу ядра

1. **Исход вызова для статистики.** Согласен ли ты добавить в `CachedService` способ узнать исход (`CacheHit` / `Coalesced` / `Executed`), например `run_traced(...) -> (Result<Arc<V>, Arc<E>>, RunOutcome)` или встроенные счётчики `CachedService::stats()`? Без этого `cacheHits` и `coalescedRequests` не различить. Это изменение в `service.rs`, не в `lib.rs`, но всё равно твоя зона.
2. **Тип ошибки ядра.** Какой `E` будет у сервиса метаданных? Предлагаю `enum CoreError { NotFound, AccessDenied, Failed(String) }` в ядре, а маппинг в коды из раздела 4 в `runtime-ipc`.
3. **Политика по умолчанию для демо.** `Ttl(30 с)`? С `Forever` вторая серия запросов всегда даёт 100 % попаданий и объединение больше не видно без инвалидации.
4. **Задержка операции.** Нужна искусственная задержка 300–500 мс в демо-операции, иначе 50 вызовов могут не пересечься и `coalescedRequests` останется 0.
5. **Команды v1.1.** Делаем `runtime_invalidate_project`, `runtime_clear_cache` и событие сразу или позже?
6. **Раскладка.** Устраивает ли отдельный крейт `crates/runtime-ipc` и кто пишет `src-tauri/src/commands.rs`: ты или я после согласования?
7. **Тестовые данные.** Какие `projectId` существуют, и какой стабильно отдаёт `PROJECT_NOT_FOUND` и `OPERATION_FAILED` для проверки ошибок в UI.
