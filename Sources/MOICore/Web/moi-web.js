'use strict';
const $ = id => document.getElementById(id);
let key = '';
let pending;
let connected = false;
let sessionID = 0;
const apiURL = location.origin + '/v1';
$('api-url').value = apiURL;

function hideKey() {
  $('api-key').type = 'password';
  $('reveal-key').textContent = 'Show what I’m typing';
  $('reveal-key').setAttribute('aria-pressed', 'false');
}
function status(id, message, error = false) {
  $(id).textContent = message;
  $(id).classList.toggle('error', error);
}
function disconnect() {
  sessionID += 1;
  if (pending) pending.abort();
  pending = undefined;
  key = ''; connected = false;
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
  status('connection-status', 'Disconnected. Your key has been cleared.');
  status('request-status', 'Connect above to get started.');
}
async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options, credentials: 'omit', cache: 'no-store',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key }
  });
  const body = await response.json();
  if (!response.ok) {
    const message = response.status === 401
      ? 'That key did not match. On the iPhone running MOI, open Connect → Reveal API key and check every character.'
      : body.error?.message || 'The phone could not complete this request.';
    throw new Error(message);
  }
  return body;
}
function messageFor(error) {
  if (error.name === 'AbortError') return 'Request cancelled.';
  if (error instanceof TypeError) return 'Cannot reach the phone. Keep MOI open and serving, and stay on the same Wi-Fi.';
  return error.message;
}
$('connect-form').addEventListener('submit', async event => {
  event.preventDefault();
  key = $('api-key').value.trim();
  if (!key) return;
  $('connect-button').disabled = true;
  const attempt = ++sessionID;
  const controller = new AbortController();
  pending = controller;
  status('connection-status', 'Checking the key…');
  try {
    const health = await api('/health', { signal: controller.signal });
    if (attempt !== sessionID) return;
    connected = true;
    $('api-key').value = '';
    hideKey();
    $('connect-form').hidden = true;
    $('disconnect').hidden = false;
    $('prompt').disabled = false;
    $('send').disabled = false;
    $('badge').textContent = 'CONNECTED';
    status('connection-status', 'Connected · ' + health.model);
    status('request-status', 'Ready when you are.');
    $('prompt').focus();
  } catch (error) {
    if (attempt !== sessionID) return;
    key = '';
    status('connection-status', messageFor(error), true);
  } finally {
    if (attempt === sessionID) {
      pending = undefined;
      $('connect-button').disabled = false;
    }
  }
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
$('disconnect').addEventListener('click', disconnect);
$('copy-url').addEventListener('click', () => {
  $('api-url').focus(); $('api-url').select();
  $('copy-url').textContent = document.execCommand('copy') ? 'Copied' : 'Select & copy';
});
window.addEventListener('pagehide', disconnect);
