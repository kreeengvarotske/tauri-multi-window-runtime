# Runtime Lab: фронтенд и TypeScript SDK

Демо-приложение для проверки Rust Core: несколько окон одновременно запрашивают одни и те же метаданные, а ядро должно объединять одинаковые запросы и кэшировать результат.

Стек: Tauri v2, Vite, TypeScript без UI-фреймворка, vitest + jsdom для тестов.

**Статус интеграции.** Rust-команд пока нет. Фронтенд полностью работает в режиме MOCK; режим TAURI собирается и запускается, но любой запрос к ядру закончится `COMMAND_NOT_FOUND`. Операции, которые нужны от ядра, описаны в [frontend-backend-contract.md](frontend-backend-contract.md) (предложение).

## Команды

```bash
npm install
npm run dev:mock     # браузер, MOCK-режим, без Rust
npm run tauri dev    # Tauri-окна, режим TAURI (нужны команды Core)
npm test             # vitest: адаптер, ошибки, UI-сценарии, граница UI/backend
npm run typecheck    # tsc --noEmit
npm run build        # tsc + vite build (TAURI)
npm run build:mock   # сборка в MOCK-режиме
```

Режим задаёт `VITE_RUNTIME_MODE` (`.env` = `tauri`, `.env.mock` = `mock`). Неизвестное значение показывается как ошибка конфигурации, молчаливого перехода в mock нет.

## Структура

```
src/
  main.ts                       точка входа: выбор режима, метка окна, mountApp
  app.ts                        сборка экрана из компонентов
  lib/
    runtime/                    слой общения с backend
      index.ts                  единственный модуль, который импортирует UI
      contract.ts               типы и имена команд из контракта
      errors.ts                 RuntimeError и нормализация отклонений
      transport.ts              интерфейс транспорта
      client.ts                 публичный API SDK, валидация, выбор режима
      tauri/tauri-transport.ts  реальная интеграция: единственное место с invoke
      mock/mock-transport.ts    mock-транспорт (только для разработки)
      mock/fixtures.ts          тестовые данные mock
    windows.ts                  метка окна, открытие второго окна (API окон Tauri)
  state/
    series.ts                   серия параллельных запросов и её итоги
    stats.ts                    инвариант счётчиков, описание политики кэша
  components/                   DOM-компоненты, получают RuntimeClient аргументом
  test/fakes.ts                 тестовые транспорты
src-tauri/                      пустая оболочка Tauri: окна, CSP, capabilities, без команд
```

## Граница UI и backend

- Компоненты получают `RuntimeClient` аргументом и импортируют только `lib/runtime` (index). `src/boundary.test.ts` падает, если UI импортирует `@tauri-apps/*` или внутренности `lib/runtime`.
- Замена mock на реальные команды: зарегистрировать команды в Rust и запустить в режиме `tauri`. UI менять не нужно; если меняется форма данных, правится `contract.ts`, и `tsc` покажет все места.
- В SDK нет дедупликации, кэша и ретраев. Окно не передаёт свою метку или права, контекст определяет ядро.

## Mock

Задержка 150–400 мс, фикстуры `demo`, `project-42`, `main-only`, `broken`, `forbidden`, остальные id → `PROJECT_NOT_FOUND`, регулируемая доля `OPERATION_FAILED`. Ошибки приходят в той же форме `{ code, message }`, что и от ядра. Статистика ядра в mock не имитируется. Mock живёт в JS одного окна и ничего не доказывает про объединение запросов между окнами; у каждого его ответа свой `computedAtMs`.

## Окна

`main` объявлено в `tauri.conf.json`, `secondary` создаётся из кода. Создавать и фокусировать окна может только `main` (`capabilities/window-management.json`). В браузере вместо окна открывается вкладка `?window=secondary` с явной пометкой.
