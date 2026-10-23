# Операции, которые нужны фронтенду от Rust Core

Статус: **предложение, ждёт одобрения владельца ядра.** Ни одна команда ниже пока не реализована в Rust: в ветке `feat/runtime-core` есть только библиотечные абстракции (`TaskCoalescer`, `CachePolicy`, `PolicyCache`, `CachedService`), а `src-tauri/src/lib.rs` не регистрирует команд.

Основа: черновик `docs/ipc-contract.md` v0.1 (PR #1). Этот документ не вводит новых команд, а раскладывает их по полям, которые нужны для интеграции: схемы, ошибки, изменяет ли операция состояние, права окон, этап. Если документы разойдутся, приоритет у `ipc-contract.md` после его согласования.

В коде контракт отражён в `src/lib/runtime/contract.ts`, вызовы делает только `src/lib/runtime/tauri/tauri-transport.ts`.

## Сводка

| Операция SDK | Команда Tauri | Изменяет состояние | Окна | Этап | В Rust | В SDK |
|---|---|---|---|---|---|---|
| `projects.getMetadata` | `runtime_get_project_metadata` | нет (заполняет кэш ядра как побочный эффект) | `main`, `secondary` | v1, обязательна | нет | да (tauri + mock) |
| `diagnostics.getStats` | `runtime_get_debug_stats` | нет | `main`, `secondary` | v1, обязательна | нет | да (tauri; в mock намеренно ошибка) |
| — | `runtime_invalidate_project` | да | только `main` | v1.1, предложение | нет | нет |
| — | `runtime_clear_cache` | да | только `main` | v1.1, предложение | нет | нет |
| — | событие `runtime://cache-invalidated` | — | все окна получают | v1.1, предложение | нет | нет |

Операции окон (создать и сфокусировать `secondary`) идут не через Core, а через встроенный API Tauri (`@tauri-apps/api/webviewWindow`, `src/lib/windows.ts`). Права на них выданы только окну `main` в `src-tauri/capabilities/window-management.json`. В контракт с ядром они не входят.

## Общие правила

- JSON в camelCase, аргументы команд тоже (`projectId`).
- Любая ошибка отклоняет Promise объектом `{ code: string, message: string }`. SDK превращает его в `RuntimeError` с тем же `code`; неизвестный `code` показывается как есть.
- Окно не передаёт свою метку, `windowId` или права. Ядро берёт контекст из `tauri::WebviewWindow` в обработчике. Метки `main` и `secondary` становятся частью контракта.
- SDK не кэширует, не объединяет запросы и не повторяет их. Каждый вызов UI доходит до `invoke`.
- Права на команды задаются capabilities (app manifest в `build.rs`). Пока ядро их не объявило, capabilities фронтенда их не упоминают.

Коды, которые создаёт только SDK: `IPC_UNAVAILABLE` (страница не в Tauri), `COMMAND_NOT_FOUND` (команда не зарегистрирована), `UNKNOWN_ERROR` (непонятное отклонение), `STATS_UNAVAILABLE_IN_MOCK`.

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

**Права:** все окна (`main`, `secondary`), разрешение `allow-runtime-get-project-metadata` в `capabilities/default.json`. Проверку доступа к конкретному проекту делает ядро.

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

**Ошибки:** `INTERNAL`.

**Права:** все окна, `allow-runtime-get-debug-stats` в `capabilities/default.json`. Только диагностика, не используется как контроль доступа.

**Этап:** v1, нужна для демонстрации объединения запросов.

**Блокер:** `CachedService::run` не сообщает исход вызова, поэтому `cacheHits` и `coalescedRequests` снаружи ядра не различить (вопрос 1 в `ipc-contract.md`).

**Mock:** всегда `STATS_UNAVAILABLE_IN_MOCK`. Поддельные счётчики выглядели бы как данные ядра, поэтому их нет.

## 3. `runtime_invalidate_project` (v1.1, предложение)

Сбросить кэш одного проекта, чтобы показать повторное вычисление без ожидания TTL.

- Вход: `{ projectId: string }`. Выход: `{ invalidated: boolean }`.
- Ошибки: `INVALID_ARGUMENT`, `ACCESS_DENIED`, `INTERNAL`.
- Изменяет состояние ядра. Только окно `main` (`allow-runtime-invalidate-project` в `capabilities/main-window.json`).
- В первом этапе не нужна. В SDK и UI не реализована.

## 4. `runtime_clear_cache` (v1.1, предложение)

Очистить весь кэш сервиса.

- Вход: нет. Выход: `null`.
- Ошибки: `ACCESS_DENIED`, `INTERNAL`.
- Изменяет состояние ядра. Только окно `main`.
- В первом этапе не нужна. В SDK и UI не реализована.

## 5. Событие `runtime://cache-invalidated` (v1.1, предложение)

Payload `{ projectId: string | null }` (`null` после `clear`), рассылается всем окнам. Только информирует: SDK сам ничего не перезапрашивает. В первом этапе не нужно.

## Что нужно от владельца ядра для v1

1. Одобрить или поправить форму `ProjectMetadata`, `RuntimeDebugStats` и ошибок.
2. Способ узнать исход вызова в `CachedService` (кэш / объединение / запуск).
3. Зарегистрировать две команды v1 и объявить их в app manifest, чтобы добавить разрешения в `capabilities/default.json`.
4. Тестовые `projectId`, включая стабильные `PROJECT_NOT_FOUND` и `OPERATION_FAILED`, чтобы заменить фикстуры mock на реальные.
5. Задержка демо-операции 300–500 мс, иначе объединение может быть не видно.
