'use strict';
const $ = id => document.getElementById(id);
const sessionStorageKey = 'moi-browser-session-v1';
const textEncoder = new TextEncoder();
let key = '';
let pending;
let connected = false;
let sending = false;
let sessionID = 0;
let chatID = 0;
let isPairedSession = false;
let followBottom = true;
let historyTurns = [];
$('api-url').value = location.origin + '/v1';

function savedSession(value) {
  try {
    if (value === undefined) return sessionStorage.getItem(sessionStorageKey) || '';
    if (value) sessionStorage.setItem(sessionStorageKey, value);
    else sessionStorage.removeItem(sessionStorageKey);
  } catch { /* Pairing still works in memory if storage is unavailable. */ }
  return '';
}
function hideKey() {
  $('api-key').type = 'password';
  $('reveal-key').textContent = 'Show key';
  $('reveal-key').setAttribute('aria-pressed', 'false');
}
function status(id, message, error = false) {
  $(id).textContent = message;
  $(id).classList.toggle('error', error);
}
function openConnection() { if (!$('connection-panel').open) $('connection-panel').showModal(); }
function updateControls() {
  $('prompt').disabled = !connected;
  $('send').disabled = !connected || sending || !$('prompt').value.trim();
  $('send').hidden = sending;
  $('cancel').hidden = !sending;
  $('messages').setAttribute('aria-busy', String(sending));
  $('empty-connect').hidden = connected;
  $('suggestions').hidden = !connected;
}
function scrollToLatest(force = false) {
  if (force || followBottom) $('chat-scroll').scrollTop = $('chat-scroll').scrollHeight;
  if (force) followBottom = true;
}
function resizeComposer() {
  $('prompt').style.height = 'auto';
  $('prompt').style.height = Math.min($('prompt').scrollHeight, 144) + 'px';
}
function newChat() {
  chatID += 1;
  if (sending) { pending?.abort(); pending = undefined; }
  sending = false; historyTurns = [];
  $('messages').replaceChildren();
  $('empty-state').hidden = false;
  $('context-note').hidden = true;
  $('prompt').value = '';
  resizeComposer(); updateControls();
  status('request-status', connected ? '' : 'Scan the QR on the iPhone to get started.');
  followBottom = true;
}
function resetConnection(message = 'Disconnected. Scan the current QR on the iPhone to reconnect.') {
  sessionID += 1;
  pending?.abort(); pending = undefined;
  key = ''; connected = false; sending = false; isPairedSession = false;
  savedSession('');
  $('api-key').value = ''; hideKey();
  $('connect-form').hidden = false;
  $('disconnect').hidden = true;
  $('connect-button').disabled = false;
  $('badge').textContent = 'Connect';
  $('status-dot').classList.remove('online');
  $('model-label').textContent = 'mom’s old iPhone';
  status('connection-status', message);
  status('request-status', 'Reconnect to continue chatting.');
  updateControls();
}
async function request(path, options = {}, credential = key) {
  const response = await fetch(path, {
    ...options, credentials: 'omit', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + credential }
  });
  if (!response.ok) {
    const body = await response.json();
    const error = new Error(body.error?.message || 'The phone could not complete this request.');
    error.status = response.status;
    throw error;
  }
  return response;
}
async function api(path, options = {}, credential = key) { return (await request(path, options, credential)).json(); }
function messageFor(error) {
  if (error.name === 'AbortError') return 'Response stopped.';
  if (error instanceof TypeError) return 'Cannot reach the phone. Keep MOI open and serving, and stay on the same Wi-Fi.';
  return error.message;
}
function showConnected(model) {
  connected = true;
  $('api-key').value = ''; hideKey();
  $('connect-form').hidden = true;
  $('disconnect').hidden = false;
  $('badge').textContent = 'Connected';
  $('status-dot').classList.add('online');
  const names = { 'qwen3-0.6b': 'Qwen 3 · on your iPhone', 'gemma-3-270m': 'Gemma 3 · on your iPhone', 'gemma-4-e2b': 'Gemma 4 · on your iPhone' };
  $('model-label').textContent = names[model] || model;
  status('connection-status', (isPairedSession ? 'Paired automatically · ' : 'Connected · ') + model);
  status('request-status', '');
  $('connection-panel').close();
  updateControls();
}
async function connect(credential, mode) {
  $('connect-form').hidden = true;
  $('connect-button').disabled = true;
  const attempt = ++sessionID;
  const controller = new AbortController(); pending = controller;
  $('badge').textContent = 'Pairing…';
  status('connection-status', mode === 'pair' ? 'Pairing with the iPhone…' : 'Connecting…');
  status('request-status', 'Connecting to your iPhone…');
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
    $('badge').textContent = 'Connect';
    let message = messageFor(error);
    if (error.status === 401 && mode !== 'pair') {
      message = mode === 'restore' ? 'This browser session ended. Scan the current QR on the iPhone to pair again.'
        : 'That key did not match. Scan the QR on the iPhone to connect without typing.';
    }
    status('connection-status', message, true);
    status('request-status', 'Open Connect to reconnect.');
    openConnection();
  } finally {
    if (attempt === sessionID) { pending = undefined; $('connect-button').disabled = false; }
  }
}
$('connect-form').addEventListener('submit', event => {
  event.preventDefault();
  let credential = $('api-key').value.replace(/\s/gu, '');
  if (/^moi_[0-9a-f]{64}$/i.test(credential)) credential = credential.toLowerCase();
  if (!credential) return;
  if (/^moi_/i.test(credential) && !/^moi_[0-9a-f]{64}$/.test(credential)) {
    status('connection-status', 'The full API key is moi_ followed by 64 letters/numbers. You can scan the QR instead.', true);
    return;
  }
  void connect(credential, 'manual');
});

// Keep complete user/assistant pairs. Dropping old context never removes the visible transcript.
function messagesFor(prompt) {
  const messages = historyTurns.flatMap(turn => [{ role: 'user', content: turn.user }, { role: 'assistant', content: turn.assistant }]);
  messages.push({ role: 'user', content: prompt });
  let bytes = messages.reduce((sum, message) => sum + textEncoder.encode(message.content).length, 0);
  let trimmed = false;
  while (messages.length > 1 && (messages.length > 13 || bytes > 2048)) {
    const removed = messages.splice(0, 2);
    bytes -= removed.reduce((sum, message) => sum + textEncoder.encode(message.content).length, 0);
    trimmed = true;
  }
  return { messages, trimmed };
}
function bubble(role, text) {
  const row = document.createElement('article'); row.className = 'message ' + role;
  const label = document.createElement('div'); label.className = 'message-label';
  if (role === 'assistant') {
    const icon = document.createElement('img'); icon.src = '/moi-icon.svg'; icon.alt = ''; label.append(icon);
  }
  const name = document.createElement('span'); name.textContent = role === 'user' ? 'You' : 'MOI'; label.append(name);
  const content = document.createElement('div'); content.className = 'message-text'; content.textContent = text;
  const meta = document.createElement('div'); meta.className = 'message-meta';
  row.append(label, content, meta); $('messages').append(row);
  return { row, content, meta };
}
function offerResend(row, prompt) {
  const button = document.createElement('button'); button.className = 'retry-button'; button.textContent = 'Edit & resend';
  button.addEventListener('click', () => {
    if (sending) return;
    $('prompt').value = prompt; resizeComposer(); updateControls(); $('prompt').focus();
  });
  row.append(button);
}
async function readReply(response, onText) {
  if (!response.body) throw new Error('This browser cannot read the reply. Try a newer browser.');
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = ''; let finish = 'stop'; let complete = false;
  function consume() {
    let boundary;
    while ((boundary = /\r?\n\r?\n/.exec(buffer))) {
      const frame = buffer.slice(0, boundary.index); buffer = buffer.slice(boundary.index + boundary[0].length);
      const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
      if (!data) continue;
      if (data === '[DONE]') { complete = true; continue; }
      const event = JSON.parse(data);
      if (event.error) { const error = new Error(event.error.message); error.status = event.error.code; throw error; }
      const choice = event.choices?.[0];
      if (typeof choice?.delta?.content === 'string') onText(choice.delta.content);
      if (choice?.finish_reason) finish = choice.finish_reason;
    }
  }
  try {
    while (!complete) {
      const chunk = await reader.read();
      buffer += decoder.decode(chunk.value, { stream: !chunk.done }); consume();
      if (chunk.done) break;
    }
    if (!complete) throw new Error('The connection ended before the reply finished. Keep MOI open and serving on the iPhone, then try again.');
    return finish;
  } finally { try { await reader.cancel(); } catch {} reader.releaseLock(); }
}
$('prompt-form').addEventListener('submit', async event => {
  event.preventDefault();
  const prompt = $('prompt').value.trim();
  if (!connected || sending || !prompt) return;
  if (textEncoder.encode(prompt).length > 2048) {
    status('request-status', 'That message is too long for this phone. Shorten it and try again.', true); return;
  }
  const context = messagesFor(prompt);
  $('context-note').hidden = !context.trimmed;
  $('empty-state').hidden = true;
  bubble('user', prompt);
  const reply = bubble('assistant', 'Thinking'); reply.content.classList.add('thinking');
  $('prompt').value = ''; resizeComposer();
  sending = true; updateControls(); status('request-status', '');
  // Keep the keyboard available after a tap on Send; the next draft remains editable.
  $('prompt').focus(); scrollToLatest(true);
  const controller = new AbortController(); pending = controller;
  const attempt = sessionID; const conversation = chatID; const start = performance.now();
  const current = () => attempt === sessionID && conversation === chatID;
  let text = '';
  try {
    const response = await request('/v1/chat/completions', {
      method: 'POST', signal: controller.signal,
      body: JSON.stringify({ model: 'moi', messages: context.messages, stream: true, max_tokens: 256 })
    });
    const finish = await readReply(response, chunk => {
      if (!current()) return;
      text += chunk;
      reply.content.textContent = text;
      reply.content.classList.remove('thinking'); reply.content.classList.add('streaming');
      scrollToLatest();
    });
    if (!current()) return;
    if (!text.trim()) throw new Error('The phone returned an empty reply. Try sending your message again.');
    reply.meta.textContent = finish === 'length' ? 'Reply limit reached · ask me to continue' : ((performance.now() - start) / 1000).toFixed(1) + 's · on your iPhone';
  } catch (error) {
    if (!current()) return;
    if (!text) reply.content.textContent = error.name === 'AbortError' ? 'Response stopped.' : 'Couldn’t finish this reply.';
    reply.meta.textContent = messageFor(error);
    reply.meta.classList.toggle('error', error.name !== 'AbortError');
    offerResend(reply.row, prompt);
    if (error.status === 401) {
      resetConnection('This browser session ended. Scan the current QR on the iPhone to pair again.');
      openConnection();
    }
  } finally {
    reply.content.classList.remove('thinking', 'streaming');
    if (current()) {
      if (text.trim()) historyTurns.push({ user: prompt, assistant: text });
      pending = undefined; sending = false; updateControls(); scrollToLatest();
    }
  }
});
$('prompt').addEventListener('input', () => { resizeComposer(); updateControls(); });
$('prompt').addEventListener('keydown', event => {
  const keyboardSend = event.metaKey || event.ctrlKey || window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && keyboardSend) {
    event.preventDefault(); if (!sending) $('prompt-form').requestSubmit();
  }
});
$('chat-scroll').addEventListener('scroll', () => {
  const view = $('chat-scroll'); followBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 80;
});
$('cancel').addEventListener('click', () => pending?.abort());
$('new-chat').addEventListener('click', () => { newChat(); if (connected) $('prompt').focus(); });
$('connection-open').addEventListener('click', openConnection);
$('empty-connect').addEventListener('click', openConnection);
$('connection-close').addEventListener('click', () => $('connection-panel').close());
$('reveal-key').addEventListener('click', () => {
  if ($('api-key').type === 'text') { hideKey(); return; }
  $('api-key').type = 'text'; $('reveal-key').textContent = 'Hide key'; $('reveal-key').setAttribute('aria-pressed', 'true');
});
$('disconnect').addEventListener('click', () => {
  const credential = key;
  if (isPairedSession) void api('/moi/unpair', { method: 'POST', body: '{}', keepalive: true }, credential).catch(() => {});
  resetConnection(); newChat();
});
$('copy-url').addEventListener('click', () => {
  $('api-url').focus(); $('api-url').select(); $('copy-url').textContent = document.execCommand('copy') ? 'Copied' : 'Select & copy';
});
function suggest(text) { $('prompt').value = text; resizeComposer(); updateControls(); $('prompt').focus(); }
$('suggest-write').addEventListener('click', () => suggest('Help me write a short thank-you note.'));
$('suggest-explain').addEventListener('click', () => suggest('Explain gravity in simple terms.'));
function fitViewport() {
  const viewport = window.visualViewport;
  document.documentElement.style.setProperty('--app-height', (viewport?.height || window.innerHeight) + 'px');
  document.documentElement.style.setProperty('--app-top', (viewport?.offsetTop || 0) + 'px');
  scrollToLatest();
}
window.visualViewport?.addEventListener('resize', fitViewport);
window.visualViewport?.addEventListener('scroll', fitViewport);
window.addEventListener('resize', fitViewport);
window.addEventListener('pagehide', () => {
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
    else { status('connection-status', 'This pairing link is incomplete. Scan the current QR on the iPhone.', true); openConnection(); }
    code = null; return;
  }
  const previous = savedSession(); if (previous) void connect(previous, 'restore');
}
fitViewport(); updateControls(); startConnection();
