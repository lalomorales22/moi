#!/usr/bin/env python3
"""Download pinned MOI models, then verify their SHA-256. No third-party packages."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def catalog():
    # The Swift catalog is the single source of truth for artifacts and hashes.
    text = (ROOT / 'Sources/MOICore/ModelCatalog.swift').read_text()
    pattern = r'ModelSpec\(id: "([^"]+)", name: "([^"]+)", summary: "([^"]+)", repository: "([^"]+)", revision: "([^"]+)", filename: "([^"]+)", bytes: (\d+), sha256: "([^"]+)", gpu: (\w+)\)'
    return {m[0]: dict(zip(('id', 'name', 'summary', 'repo', 'revision', 'filename', 'bytes', 'sha256', 'gpu'), m)) for m in re.findall(pattern, text)}


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def main():
    models = catalog()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', choices=list(models))
    args = parser.parse_args()
    model = models[args.model]
    folder = ROOT / 'models'
    folder.mkdir(exist_ok=True)
    target = folder / model['filename']
    size = int(model['bytes'])
    if target.exists() and target.stat().st_size == size and digest(target) == model['sha256']:
        print(f'Already verified: {target}')
        return
    url = f"https://huggingface.co/{model['repo']}/resolve/{model['revision']}/{model['filename']}"
    headers = {}
    if os.getenv('HF_TOKEN'):
        headers['Authorization'] = f"Bearer {os.environ['HF_TOKEN']}"
    partial = target.with_suffix('.partial')
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response, partial.open('wb') as output:
            received = 0
            last_percent = -1
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > size:
                    raise ValueError('Download exceeded catalog size')
                output.write(chunk)
                percent = int(received * 100 / size)
                if percent // 10 > last_percent // 10:
                    print(f"{model['name']}: {percent}%", flush=True)
                    last_percent = percent
        if partial.stat().st_size != size or digest(partial) != model['sha256']:
            raise ValueError('Model checksum or size mismatch')
        partial.replace(target)
        print(f'Verified: {target}')
    except urllib.error.HTTPError as error:
        print(f'Download returned HTTP {error.code}. For gated models, accept the repository terms and set HF_TOKEN to a read token.', file=sys.stderr)
        sys.exit(1)
    finally:
        partial.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
