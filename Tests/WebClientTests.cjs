const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('Sources/MOICore/Web/moi-web.js', 'utf8');
const storageKey = 'moi-browser-session-v1';
const invitation = 'a'.repeat(64);
const token = 'moi_browser_' + 'b'.repeat(64);
const tick = () => new Promise(resolve => setImmediate(resolve));
function client({ hash = '', stored = '', respond = () => ({ status: 200, body: { model: 'test-model', token } }) } = {}) {
  const elements = new Map();
  const storage = new Map(stored ? [[storageKey, stored]] : []);
  const requests = [];
  const location = { origin: 'http://192.0.2.1:8080', pathname: '/', search: '', hash, reload() {} };
  const makeElement = () => ({ value: '', type: 'password', hidden: false, disabled: false, textContent: '', open: false,
    children: [], scrollHeight: 44, scrollTop: 0, clientHeight: 600, style: { setProperty() {} },
    listeners: {}, classList: { toggle() {}, add() {}, remove() {} }, setAttribute(name, value) { this[name] = value; },
    addEventListener(name, callback) { this.listeners[name] = callback; }, focus() {}, select() {},
    append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; },
    showModal() { this.open = true; }, close() { this.open = false; },
    requestSubmit() { return this.listeners.submit({ preventDefault() {} }); }
  });
  const element = id => { if (!elements.has(id)) elements.set(id, makeElement()); return elements.get(id); };
  const pageEvents = {};
  vm.runInNewContext(source, {
    document: { getElementById: element, createElement: makeElement, documentElement: makeElement(), execCommand: () => true }, location,
    history: { replaceState(_state, _title, url) { assert.equal(url, '/'); location.hash = ''; } },
    sessionStorage: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    window: { innerHeight: 844, matchMedia: () => ({ matches: true }), addEventListener: (name, cb) => { pageEvents[name] = cb; } },
    fetch: async (path, options) => {
      requests.push({ path, options, hashAtRequest: location.hash });
      const result = respond(path, options);
      return { ok: result.status < 400, status: result.status, json: async () => result.body, body: result.stream };
    }, URLSearchParams, AbortController, TextEncoder, TextDecoder, performance,
  });
  return { element, storage, requests, location, pageEvents };
}

test('QR exchanges a fragment once, stores only the browser token, and reconnects after refresh', async () => {
  const page = client({ hash: '#pair=' + invitation });
  await tick();
  assert.equal(page.requests[0].path, '/moi/pair');
  assert.equal(page.requests[0].hashAtRequest, '');
  assert.equal(page.requests[0].options.headers.Authorization, 'Bearer ' + invitation);
  assert.equal(page.storage.get(storageKey), token);
  assert.equal(page.element('badge').textContent, 'Connected');
  page.pageEvents.pagehide();
  assert.equal(page.storage.get(storageKey), token);
  const refreshed = client({ stored: page.storage.get(storageKey) });
  await tick();
  assert.equal(refreshed.requests[0].path, '/health');
  assert.equal(refreshed.requests[0].options.headers.Authorization, 'Bearer ' + token);
  assert.equal(refreshed.element('badge').textContent, 'Connected');
});

test('expired pairing shows the server error and clears stale browser storage', async () => {
  const page = client({ hash: '#pair=' + invitation, stored: token,
    respond: () => ({ status: 401, body: { error: { message: 'Scan the current QR.' } } }) });
  await tick();
  assert.equal(page.element('connection-status').textContent, 'Scan the current QR.');
  assert.equal(page.element('connect-form').hidden, false);
  assert.equal(page.storage.size, 0);
});

test('manual native keys tolerate keyboard case and whitespace without being persisted', async () => {
  const key = 'moi_' + 'ab12'.repeat(16);
  const page = client();
  page.element('api-key').value = '  MOI_ ' + 'AB12 '.repeat(16) + '\n';
  await page.element('connect-form').listeners.submit({ preventDefault() {} });
  await tick();
  assert.equal(page.requests[0].options.headers.Authorization, 'Bearer ' + key);
  assert.equal(page.storage.size, 0);
  assert.equal(page.element('api-key').value, '');
  assert.equal(page.element('badge').textContent, 'Connected');
});

test('disconnect revokes a paired session and clears browser storage', async () => {
  const page = client({ hash: '#pair=' + invitation });
  await tick();
  page.element('disconnect').listeners.click();
  await tick();
  const revoke = page.requests.find(request => request.path === '/moi/unpair');
  assert.equal(revoke.options.headers.Authorization, 'Bearer ' + token);
  assert.equal(page.storage.size, 0);
  assert.equal(page.element('send').disabled, true);
});

function streamReply(text, finish = 'stop') {
  const wire = 'data: ' + JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: null }] }) + '\n\n'
    + 'data: ' + JSON.stringify({ choices: [{ delta: {}, finish_reason: finish }] }) + '\n\n'
    + 'data: [DONE]\n\n';
  const bytes = new TextEncoder().encode(wire);
  return new ReadableStream({ start(controller) {
    // Fragment every UTF-8 byte to exercise incremental text and SSE decoding.
    for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
    controller.close();
  } });
}
function chatClient(reply = 'Hello 🌱 <b>plain text</b>') {
  return client({ stored: token, respond: path => path === '/v1/chat/completions'
    ? { status: 200, stream: streamReply(reply) } : { status: 200, body: { model: 'test-model' } } });
}
async function send(page, text) {
  page.element('prompt').value = text;
  return page.element('prompt-form').requestSubmit();
}
function chats(page) { return page.requests.filter(request => request.path === '/v1/chat/completions').map(request => JSON.parse(request.options.body)); }

test('chat clears the composer, streams safe text, and sends earlier turns with the follow-up', async () => {
  const page = chatClient(); await tick();
  const first = send(page, 'My cat is named Mango.');
  assert.equal(page.element('prompt').value, '');
  assert.equal(page.element('prompt').disabled, false, 'Typing the next draft stays available');
  page.element('prompt').value = 'What is my cat called?';
  await first;
  assert.equal(page.element('prompt').value, 'What is my cat called?', 'Receiving a reply must not overwrite a draft');
  await page.element('prompt-form').requestSubmit();
  const requests = chats(page);
  assert.equal(requests[0].stream, true);
  assert.deepEqual(requests[1].messages, [
    { role: 'user', content: 'My cat is named Mango.' },
    { role: 'assistant', content: 'Hello 🌱 <b>plain text</b>' },
    { role: 'user', content: 'What is my cat called?' }
  ]);
  assert.equal(page.element('messages').children.length, 4);
  assert.equal(page.element('messages').children[1].children[1].textContent, 'Hello 🌱 <b>plain text</b>');
});

test('long chats trim complete pairs to API limits while preserving the visible transcript', async () => {
  const page = chatClient('A'.repeat(400)); await tick();
  for (let turn = 0; turn < 9; turn++) await send(page, '🌱'.repeat(50) + turn);
  const last = chats(page).at(-1).messages;
  assert.ok(last.length <= 13);
  assert.ok(last.reduce((sum, message) => sum + Buffer.byteLength(message.content), 0) <= 2048);
  last.forEach((message, index) => assert.equal(message.role, index % 2 ? 'assistant' : 'user'));
  assert.equal(last.at(-1).content, '🌱'.repeat(50) + '8');
  assert.equal(page.element('messages').children.length, 18);
  assert.equal(page.element('context-note').hidden, false);
});

test('New chat clears context and the transcript without disconnecting', async () => {
  const page = chatClient(); await tick(); await send(page, 'remember this');
  page.element('new-chat').listeners.click();
  assert.equal(page.element('messages').children.length, 0);
  assert.equal(page.element('badge').textContent, 'Connected');
  await send(page, 'fresh start');
  assert.deepEqual(chats(page).at(-1).messages, [{ role: 'user', content: 'fresh start' }]);
});

test('an interrupted stream keeps partial text, allows recovery, and preserves the next draft', async () => {
  let controller;
  const page = client({ stored: token, respond: (path, options) => {
    if (path !== '/v1/chat/completions') return { status: 200, body: { model: 'test' } };
    return { status: 200, stream: new ReadableStream({ start(value) {
      controller = value;
      value.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"content":"Partial reply"}}]}\n\n'));
      options.signal.addEventListener('abort', () => value.error(new DOMException('Stopped', 'AbortError')), { once: true });
    } }) };
  } });
  await tick();
  const pending = send(page, 'a long question'); await tick();
  page.element('prompt').value = 'my next draft';
  page.element('cancel').listeners.click(); await pending;
  assert.equal(page.element('messages').children[1].children[1].textContent, 'Partial reply');
  assert.equal(page.element('messages').children[1].children[2].textContent, 'Response stopped.');
  assert.equal(page.element('prompt').value, 'my next draft');
  assert.equal(page.element('cancel').hidden, true);
  assert.equal(page.element('send').disabled, false);
});

test('failed replies are visible and do not inject an unmatched user turn into later context', async () => {
  let calls = 0;
  const page = client({ stored: token, respond: path => {
    if (path !== '/v1/chat/completions') return { status: 200, body: { model: 'test' } };
    calls++;
    return calls === 1 ? { status: 429, body: { error: { message: 'The phone is busy.' } } }
      : { status: 200, stream: streamReply('Ready now.') };
  } });
  await tick(); await send(page, 'first attempt');
  assert.equal(page.element('messages').children[1].children[2].textContent, 'The phone is busy.');
  await send(page, 'second attempt');
  assert.deepEqual(chats(page).at(-1).messages, [{ role: 'user', content: 'second attempt' }]);
});

test('New chat during a reply ignores late output and preserves the new conversation', async () => {
  let oldStream;
  let calls = 0;
  const page = client({ stored: token, respond: path => {
    if (path !== '/v1/chat/completions') return { status: 200, body: { model: 'test' } };
    calls++;
    return { status: 200, stream: calls === 1 ? new ReadableStream({ start(controller) { oldStream = controller; } }) : streamReply('Fresh reply') };
  } });
  await tick();
  const old = send(page, 'old question'); await tick();
  page.element('new-chat').listeners.click();
  await send(page, 'new question');
  oldStream.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"content":"Late old reply"}}]}\n\ndata: [DONE]\n\n'));
  oldStream.close(); await old;
  assert.equal(page.element('messages').children.length, 2);
  assert.equal(page.element('messages').children[1].children[1].textContent, 'Fresh reply');
  await send(page, 'follow up');
  assert.deepEqual(chats(page).at(-1).messages, [
    { role: 'user', content: 'new question' }, { role: 'assistant', content: 'Fresh reply' }, { role: 'user', content: 'follow up' }
  ]);
});

test('oversized multibyte messages preserve the draft and never reach inference', async () => {
  const page = chatClient(); await tick();
  const draft = '🌱'.repeat(513);
  await send(page, draft);
  assert.equal(chats(page).length, 0);
  assert.equal(page.element('messages').children.length, 0);
  assert.equal(page.element('prompt').value, draft);
  assert.match(page.element('request-status').textContent, /too long/);
});

test('a truncated stream keeps its partial reply and explains that MOI must stay open', async () => {
  const page = client({ stored: token, respond: path => path === '/v1/chat/completions'
    ? { status: 200, stream: new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"content":"Not finished"}}]}\n\n'));
      controller.close();
    } }) } : { status: 200, body: { model: 'test' } } });
  await tick(); await send(page, 'hello');
  assert.equal(page.element('messages').children[1].children[1].textContent, 'Not finished');
  assert.match(page.element('messages').children[1].children[2].textContent, /Keep MOI open and serving/);
  assert.equal(page.element('cancel').hidden, true);
});
