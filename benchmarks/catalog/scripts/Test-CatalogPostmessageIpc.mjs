import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import vm from 'node:vm'

const source = readFileSync(new URL('../src-tauri/src/postmessage-ipc-diagnostic.js', import.meta.url), 'utf8')
const key = 'diagnostic-integrity-key-123'

function transport() {
  const messages = []
  const window = {
    __TAURI_INTERNALS__: {},
    ipc: { postMessage: (message) => messages.push(message) }
  }
  const context = { window, fetch: () => assert.fail('diagnostic IPC must not fetch') }
  assert.equal(source.split('__INVOKE_KEY__').length, 2, 'exactly one Builder replacement token')
  vm.runInNewContext(source.replace('__INVOKE_KEY__', JSON.stringify(key)), context)
  return { window, context, messages, send: window.__TAURI_INTERNALS__.postMessage }
}

test('preserves catalog commands, JSON payloads and both callback IDs', () => {
  const { messages, send } = transport()
  const calls = [
    { cmd: 'catalog_page', payload: { query: { sort: 'price', category: 3, offset: 100, limit: 100 } } },
    { cmd: 'catalog_get', payload: { ids: [0, 17, 999999] } },
    { cmd: 'catalog_aggregate', payload: {} },
    { cmd: 'catalog_window_report', payload: { report: '{"passed":true,"note":"quote \\\"; < > & ü"}' } }
  ]
  for (const [index, call] of calls.entries()) send({ ...call, callback: index * 2, error: index * 2 + 1 })
  assert.equal(messages.length, calls.length)
  for (const [index, serialized] of messages.entries()) {
    assert.equal(typeof serialized, 'string')
    assert.deepEqual(JSON.parse(serialized), {
      ...calls[index], callback: index * 2, error: index * 2 + 1,
      options: { customProtocolIpcBlocked: true }, __TAURI_INVOKE_KEY__: key
    })
  }
})

test('preserves headers and options while forcing fallback responses without mutating inputs', () => {
  const { messages, send } = transport()
  const options = { headers: { 'X-Test': 'value', 'Content-Type': 'application/json' }, customProtocolIpcBlocked: false, other: { enabled: true } }
  const before = JSON.stringify(options)
  send({ cmd: 'catalog_plan', callback: 1, error: 2, payload: {}, options })
  assert.deepEqual(JSON.parse(messages[0]).options, { ...options, customProtocolIpcBlocked: true })
  assert.equal(JSON.stringify(options), before)
})

test('keeps the integrity key in its closure and refuses a spoofed envelope key', () => {
  const { window, context, messages, send } = transport()
  assert.equal(send.toString().includes(key), false)
  assert.equal(Object.hasOwn(window, 'invokeKey'), false)
  assert.equal(Object.hasOwn(context, 'invokeKey'), false)
  send({ cmd: 'catalog_ready', callback: 10, error: 11, payload: {}, __TAURI_INVOKE_KEY__: 'spoofed' })
  assert.equal(JSON.parse(messages[0]).__TAURI_INVOKE_KEY__, key)
})

test('treats prototype-looking JSON keys as data and keeps options separate from the envelope', () => {
  const { messages, send } = transport()
  const options = JSON.parse('{"__proto__":{"polluted":true},"cmd":"spoofed","callback":999,"__TAURI_INVOKE_KEY__":"spoofed"}')
  const payload = JSON.parse('{"__proto__":{"polluted":true},"constructor":{"prototype":{"polluted":true}}}')
  send({ cmd: 'catalog_workload', callback: 3, error: 4, payload, options })
  const message = JSON.parse(messages[0])
  assert.equal(message.cmd, 'catalog_workload')
  assert.equal(message.callback, 3)
  assert.equal(message.error, 4)
  assert.equal(message.__TAURI_INVOKE_KEY__, key)
  assert.deepEqual(message.payload, payload)
  assert.deepEqual(message.options, { ...options, customProtocolIpcBlocked: true })
  assert.equal(Object.hasOwn(message.options, '__proto__'), true)
  assert.equal(({}).polluted, undefined)
  assert.equal(Object.getPrototypeOf(options), Object.prototype)
})

test('does not install an alternate global or expose a writable transport property', () => {
  const { window, context } = transport()
  assert.deepEqual(Object.keys(context).sort(), ['fetch', 'window'])
  assert.deepEqual(Object.keys(window).sort(), ['__TAURI_INTERNALS__', 'ipc'])
  const descriptor = Object.getOwnPropertyDescriptor(window.__TAURI_INTERNALS__, 'postMessage')
  assert.equal(descriptor.writable, false)
  assert.equal(descriptor.configurable, false)
})
