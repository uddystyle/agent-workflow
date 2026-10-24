#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util
import io
import json
import os
from pathlib import Path
from unittest.mock import patch

root = Path(os.environ['REPO'])
skill = (root / 'home/.agents/skills/decision-assisted-implementation/SKILL.md').read_text()
assert 'disable-model-invocation: true' in skill
assert skill.index('git diff') < skill.index('jev-decision.py')
assert 'herdr agent get' in skill and 'herdr agent read' in skill
path = root / 'home/.agents/skills/decision-assisted-implementation/jev-decision.py'
spec = importlib.util.spec_from_file_location('jev_decision', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Response:
    def __enter__(self): return io.BytesIO(json.dumps({'answers': {'next': {'type': 'choice', 'choice': 'RETRY', 'confidence': .8}}}).encode())
    def __exit__(self, *args): pass

with patch.object(module, 'urlopen', return_value=Response()) as send:
    assert module.decide('approved summary', 'test-key') == {'choice': 'RETRY', 'confidence': .8}
    request = send.call_args.args[0]
    assert request.full_url == 'https://api.typesafe.ai/v1/systemone'
    assert json.loads(request.data)['state'] == 'approved summary'
    assert 'test-key' not in request.data.decode()
    assert send.call_args.kwargs['timeout'] == 20

class BadResponse(Response):
    def __enter__(self): return io.BytesIO(b'{"answers":{"next":{"type":"choice","choice":"DONE","confidence":1}}}')
with patch.object(module, 'urlopen', return_value=BadResponse()):
    try: module.decide('approved summary', 'test-key')
    except ValueError: pass
    else: raise AssertionError('unknown decisions must be rejected')
with patch.object(module, 'urlopen') as send, patch.dict(os.environ, {'TYPESAFE_API_KEY': 'test-key'}), patch.object(module.sys, 'stdin', io.StringIO('x' * 4097)):
    try: module.main()
    except ValueError: pass
    else: raise AssertionError('oversized summaries must be rejected')
    send.assert_not_called()
print('PASS bounded Jev decision (mocked; no network)')
PY
