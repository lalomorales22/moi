#!/usr/bin/env python3
"""Exercise a running MOI instance. Does real inference; no third-party packages."""
import json
import os
import sys
import urllib.error
import urllib.request

base = sys.argv[1].rstrip('/') if len(sys.argv) > 1 else 'http://127.0.0.1:8081'
key = os.environ.get('MOI_API_KEY', '')
if not key:
    sys.exit('Set MOI_API_KEY before running this script.')


def request(path, payload=None, auth=True):
    headers = {'Content-Type': 'application/json'}
    if auth:
        headers['Authorization'] = 'Bearer ' + key
    body = json.dumps(payload).encode() if payload is not None else None
    try:
        with urllib.request.urlopen(urllib.request.Request(base + path, data=body, headers=headers), timeout=180) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


code, _ = request('/health', auth=False)
assert code == 401, ('authentication', code)
print('PASS: rejects unauthenticated requests')
code, body = request('/v1/models')
assert code == 200
model = json.loads(body)['data'][0]['id']
print('PASS: model listing:', model)
payload = {'model': model, 'messages': [{'role': 'user', 'content': 'Reply with a short greeting.'}], 'max_tokens': 32, 'temperature': 0.2}
code, body = request('/v1/chat/completions', payload | {'max_tokens': 100000})
assert code == 400, ('output limit', code)
code, body = request('/v1/chat/completions', payload | {'tools': []})
assert code == 400, ('unsupported tools', code)
print('PASS: rejects oversized generation and unsupported features')
code, body = request('/v1/chat/completions', payload)
assert code == 200, (code, body.decode())
result = json.loads(body)
assert result['choices'][0]['message']['content'].strip(), result
print('PASS: real non-streaming inference:', result['choices'][0]['message']['content'])
print('Usage:', result.get('usage', 'unavailable'))
code, body = request('/v1/chat/completions', payload | {'stream': True})
assert code == 200
frames = [line[6:] for line in body.decode().splitlines() if line.startswith('data: ')]
assert frames[-1] == '[DONE]', frames
chunks = [json.loads(frame) for frame in frames[:-1]]
assert any(chunk.get('choices', [{}])[0].get('delta', {}).get('content') for chunk in chunks), chunks
assert chunks[-1]['choices'][0]['finish_reason'] in ('stop', 'length')
print('PASS: real SSE streaming and completion marker')
code, body = request('/moi/stats')
assert code == 200
stats = json.loads(body)
assert stats['completed_requests'] >= 2
print('PASS: stats', json.dumps(stats, indent=2))
