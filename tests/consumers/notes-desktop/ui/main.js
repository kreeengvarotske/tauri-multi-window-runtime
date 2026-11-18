const invoke = window.__TAURI__.core.invoke;
const decode = value => JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(value)));
(async () => {
  let success = false;
  try {
    const seconds = await invoke('qualification');
    const first = decode(await invoke('note', { text: 'draft' }));
    const second = decode(await invoke('note', { text: 'draft' }));
    if (first !== 'draft' || second !== 'draft') throw new Error('wrong note');
    const escaped = '\u0000'.repeat(64);
    if (decode(await invoke('note', { text: escaped })) !== escaped) throw new Error('escaped note changed');
    try {
      await invoke('note', { text: 'x'.repeat(65) });
      throw new Error('oversized note accepted');
    } catch (error) {
      if (error?.code !== 'INVALID_ARGUMENT') throw error;
    }
    try {
      await invoke('note', { text: 'draft', window: 'forged' });
      throw new Error('forged identity accepted');
    } catch (error) {
      if (error?.code !== 'INVALID_ARGUMENT') throw error;
    }
    const until = performance.now() + seconds * 1000;
    while (performance.now() < until) {
      for (let i = 0; i < 10; i++) {
        if (decode(await invoke('note', { text: 'draft' })) !== 'draft') throw new Error('soak changed note');
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    success = true;
  } finally {
    await invoke('finish', { success });
  }
})();
