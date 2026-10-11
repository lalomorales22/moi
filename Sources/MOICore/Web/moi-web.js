'use strict';
const $ = id => document.getElementById(id);
const sessionStorageKey = 'moi-browser-session-v1';
let key = '';
let pending;
let connected = false;
let sessionID = 0;
let isPairedSession = false;
$('api-url').value = location.origin + '/v1';

function savedSession(value) {
  try {
    if (value === undefined) return sessionStorage.getItem(sessionStorageKey) || '';
    if (value) sessionStorage.setItem(sessionStorageKey, value);
    else sessionStorage.removeItem(sessionStorageKey);
  } catch { /* Private browser settings may limit persistence; pairing still works in memory. */ }
  return '';
}
function hideKey() {
  $('api-key').type = 'password';
  $('reveal-key').textContent = 'Show what I’m typing';
  $('reveal-key').setAttribute('aria-pressed', 'false');
}
function status(id, message, error = false) {
  $(id).textContent = message;
  $(id).classList.toggle('error', error);
}
function resetConnection(message = 'Disconnected. Scan the current QR on the iPhone to reconnect.') {
  sessionID += 1;
  pending?.abort(); pending = undefined;
  key = ''; connected = false; isPairedSession = false;
  savedSession('');
  $('api-key').value = '';
  hideKey();
  $('connect-form').hidden = false;
  $('disconnect').hidden = true;
  $('connect-button').disabled = false;
  $('cancel').hidden = true;
  $('prompt').disabled = true;
  $('send').disabled = true;
  $('badge').textContent = 'PHONE REACHED';
  $('answer').hidden = true;
  $('answer-text').textContent = '';
  status('connection-status', message);
  status('request-status', 'Connect above to get started.');
}
async function api(path, options = {}, credential = key) {
  const response = await fetch(path, {
    ...options, credentials: 'omit', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + credential }
  });
  const body = await response.json();
  if (!response.ok) {
    const error = new Error(body.error?.message || 'The phone could not complete this request.');
    error.status = response.status;
    throw error;
  }
  return body;
}
function messageFor(error) {
  if (error.name === 'AbortError') return 'Request cancelled.';
  if (error instanceof TypeError) return 'Cannot reach the phone. Keep MOI open and serving, and stay on the same Wi-Fi.';
  return error.message;
}
function showConnected(model) {
  connected = true;
  $('api-key').value = '';
  hideKey();
  $('connect-form').hidden = true;
  $('disconnect').hidden = false;
  $('prompt').disabled = false;
  $('send').disabled = false;
  $('badge').textContent = 'CONNECTED';
  status('connection-status', (isPairedSession ? 'Paired automatically · ' : 'Connected · ') + model);
  status('request-status', 'Ready when you are.');
}
async function connect(credential, mode) {
  $('connect-form').hidden = true;
  $('connect-button').disabled = true;
  const attempt = ++sessionID;
  const controller = new AbortController();
  pending = controller;
  status('connection-status', mode === 'pair' ? 'Pairing with the iPhone…' : 'Connecting…');
  try {
    const result = mode === 'pair'
      ? await api('/moi/pair', { method: 'POST', body: '{}', signal: controller.signal }, credential)
      : await api('/health', { signal: controller.signal }, credential);
    if (attempt !== sessionID) return;
    key = mode === 'pair' ? result.token : credential;
    isPairedSession = mode !== 'manual';
    savedSession(isPairedSession ? key : '');
    showConnected(result.model);
  } catch (error) {
    if (attempt !== sessionID) return;
    key = ''; savedSession('');
    $('connect-form').hidden = false;
    let message = messageFor(error);
    if (error.status === 401 && mode !== 'pair') {
      message = mode === 'restore' ? 'This browser session ended. Scan the current QR on the iPhone to pair again.'
        : 'That key did not match. Scan the QR on the iPhone to connect without typing.';
    }
    status('connection-status', message, true);
  } finally {
    if (attempt === sessionID) {
      pending = undefined;
      $('connect-button').disabled = false;
    }
  }
}
$('connect-form').addEventListener('submit', event => {
  event.preventDefault();
  let credential = $('api-key').value.replace(/\s/gu, '');
  // Native keys are lowercase hex. Ignore keyboard capitalization and visual line breaks.
  if (/^moi_[0-9a-f]{64}$/i.test(credential)) credential = credential.toLowerCase();
  if (!credential) return;
  if (/^moi_/i.test(credential) && !/^moi_[0-9a-f]{64}$/.test(credential)) {
    status('connection-status', 'The full API key is moi_ followed by 64 letters/numbers (68 characters total). You can scan the QR instead.', true);
    return;
  }
  void connect(credential, 'manual');
});
$('prompt-form').addEventListener('submit', async event => {
  event.preventDefault();
  const prompt = $('prompt').value.trim();
  if (!connected || !prompt) return;
  if (new TextEncoder().encode(prompt).length > 2048) {
    status('request-status', 'That prompt is too long for this phone. Shorten it and try again.', true);
    return;
  }
  $('send').disabled = true;
  $('prompt').disabled = true;
  $('cancel').hidden = false;
  $('answer').hidden = true;
  const controller = new AbortController();
  pending = controller;
  const start = performance.now();
  const attempt = sessionID;
  status('request-status', 'The phone is thinking…');
  try {
    const result = await api('/v1/chat/completions', {
      method: 'POST', signal: controller.signal,
      body: JSON.stringify({ model: 'moi', messages: [{ role: 'user', content: prompt }], max_tokens: 128 })
    });
    if (attempt !== sessionID) return;
    $('answer-text').textContent = result.choices[0].message.content;
    const tokens = result.usage?.completion_tokens;
    $('answer-meta').textContent = ((performance.now() - start) / 1000).toFixed(1) + ' sec' + (tokens == null ? '' : ' · ' + tokens + ' output tokens');
    $('answer').hidden = false;
    status('request-status', result.choices[0].finish_reason === 'length' ? 'Reached the response limit. Try a shorter question for a complete answer.' : 'Done — generated on the iPhone.');
  } catch (error) {
    if (attempt !== sessionID) return;
    if (error.status === 401) {
      resetConnection('This browser session ended. Scan the current QR on the iPhone to pair again.');
      return;
    }
    status('request-status', messageFor(error), true);
  } finally {
    if (attempt === sessionID) {
      pending = undefined;
      $('send').disabled = !connected;
      $('prompt').disabled = !connected;
      $('cancel').hidden = true;
    }
  }
});
$('cancel').addEventListener('click', () => pending?.abort());
$('reveal-key').addEventListener('click', () => {
  if ($('api-key').type === 'text') { hideKey(); return; }
  $('api-key').type = 'text';
  $('reveal-key').textContent = 'Hide key';
  $('reveal-key').setAttribute('aria-pressed', 'true');
});
$('disconnect').addEventListener('click', () => {
  const credential = key;
  if (isPairedSession) void api('/moi/unpair', { method: 'POST', body: '{}', keepalive: true }, credential).catch(() => {});
  resetConnection();
});
$('copy-url').addEventListener('click', () => {
  $('api-url').focus(); $('api-url').select();
  $('copy-url').textContent = document.execCommand('copy') ? 'Copied' : 'Select & copy';
});
window.addEventListener('pagehide', () => {
  // Retain only a station-scoped browser credential in this tab's session storage.
  // Main API keys entered manually never enter browser storage.
  sessionID += 1; pending?.abort(); pending = undefined;
  key = ''; connected = false;
  $('api-key').value = ''; hideKey();
});
window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });

function startConnection() {
  let code = new URLSearchParams(location.hash.slice(1)).get('pair');
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  if (code) {
    savedSession('');
    if (/^[0-9a-f]{64}$/.test(code)) void connect(code, 'pair');
    else status('connection-status', 'This pairing link is incomplete. Scan the current QR on the iPhone.', true);
    code = null;
    return;
  }
  const previous = savedSession();
  if (previous) void connect(previous, 'restore');
}
startConnection();
