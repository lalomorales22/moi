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
  const element = id => {
    if (!elements.has(id)) elements.set(id, { value: '', type: 'password', hidden: false, disabled: false, textContent: '',
      listeners: {}, classList: { toggle() {} }, setAttribute(name, value) { this[name] = value; },
      addEventListener(name, callback) { this.listeners[name] = callback; }, focus() {}, select() {} });
    return elements.get(id);
  };
  const pageEvents = {};
  vm.runInNewContext(source, {
    document: { getElementById: element, execCommand: () => true }, location,
    history: { replaceState(_state, _title, url) { assert.equal(url, '/'); location.hash = ''; } },
    sessionStorage: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
    window: { addEventListener: (name, cb) => { pageEvents[name] = cb; } },
    fetch: async (path, options) => {
      requests.push({ path, options, hashAtRequest: location.hash });
      const result = respond(path, options);
      return { ok: result.status < 400, status: result.status, json: async () => result.body };
    }, URLSearchParams, AbortController, TextEncoder, performance,
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
  assert.equal(page.element('badge').textContent, 'CONNECTED');
  page.pageEvents.pagehide();
  assert.equal(page.storage.get(storageKey), token);
  const refreshed = client({ stored: page.storage.get(storageKey) });
  await tick();
  assert.equal(refreshed.requests[0].path, '/health');
  assert.equal(refreshed.requests[0].options.headers.Authorization, 'Bearer ' + token);
  assert.equal(refreshed.element('badge').textContent, 'CONNECTED');
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
  assert.equal(page.element('badge').textContent, 'CONNECTED');
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
