#!/usr/bin/env python3
"""A complete MOI client using Python's standard library."""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stream', action='store_true')
    parser.add_argument('prompt')
    args = parser.parse_args()
    key = os.environ.get('MOI_API_KEY')
    base = os.environ.get('MOI_BASE_URL', '').rstrip('/')
    if not key or not base:
        sys.exit('Set MOI_API_KEY and MOI_BASE_URL (for example http://192.168.1.20:8080).')
    payload = {'model': 'moi', 'messages': [{'role': 'user', 'content': args.prompt}], 'max_tokens': 128, 'stream': args.stream}
    request = urllib.request.Request(base + '/v1/chat/completions', data=json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key})
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            if not args.stream:
                print(json.load(response)['choices'][0]['message']['content'])
                return
            done = False
            for line in response:
                if not line.startswith(b'data: '):
                    continue
                event = line[6:].decode().strip()
                if event == '[DONE]':
                    done = True
                    break
                chunk = json.loads(event)
                if 'error' in chunk:
                    sys.exit('\nMOI: ' + chunk['error']['message'])
                print(chunk['choices'][0]['delta'].get('content', ''), end='', flush=True)
            print()
            if not done:
                sys.exit('The stream ended before completion. Check the phone and try again.')
    except urllib.error.HTTPError as error:
        sys.exit(f'MOI returned HTTP {error.code}: {error.read().decode()}')
    except (urllib.error.URLError, TimeoutError) as error:
        sys.exit(f'Cannot reach MOI: {error}. Keep the app open on the same network.')


if __name__ == '__main__':
    main()
