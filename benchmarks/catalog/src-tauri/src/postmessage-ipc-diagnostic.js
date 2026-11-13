// Diagnostic only, for this app's JSON command inputs. Based on the fallback
// envelope in Tauri 2.12.5 scripts/ipc-protocol.js, installed through the public
// Builder::invoke_system hook. This is not a general-purpose Tauri transport:
// binary inputs, channels and custom IPC serializers are outside its scope.
;(function () {
  // Keep the injected integrity key out of the exposed function's source.
  const invokeKey = __INVOKE_KEY__

  Object.defineProperty(window.__TAURI_INTERNALS__, 'postMessage', {
    value: function (message) {
      const { cmd, callback, error, payload, options } = message
      window.ipc.postMessage(JSON.stringify({
        cmd,
        callback,
        error,
        options: {
          ...options,
          // Also force eval-based responses: otherwise Tauri may send object
          // responses through a Channel, which fetches the custom protocol.
          customProtocolIpcBlocked: true
        },
        payload,
        __TAURI_INVOKE_KEY__: invokeKey
      }))
    }
  })
})()
