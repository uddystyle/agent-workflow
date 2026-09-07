#!/usr/bin/env bash
# skill の配信契約と、同梱 subagent の登録まで。モデルや Herdr pane は起動しない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" python3 - <<'PY'
from pathlib import Path
import os,re
r=Path(os.environ['REPO'])
def text(p): return (r/p).read_text()
review=text('skills/code-review/SKILL.md')
assert 'name: code-review' in review
assert 'agentScope: user' in review
assert 'agent: standards' in review and 'agent: spec' in review
assert 'snapshot' in review and '未コミット' in review
assert '仕様なし' in review and '未評価' in review
alias=text('skills/two-axis-review/SKILL.md')
assert 'disable-model-invocation: true' in alias
assert '../code-review/SKILL.md' in alias
assert 'disable-model-invocation: true' not in text('skills/worktrees/SKILL.md')
plannotator=text('skills/plannotator-tui/SKILL.md')
assert 'name: plannotator-tui' in plannotator
assert 'HERDR_ENV=1' in plannotator
assert 'plannotator-tui herdr open' in plannotator
assert 'End your turn' in plannotator
assert 'file://' in plannotator
assert 'MIT License' in text('skills/plannotator-tui/LICENSE')
assert '人に頼んで待つ' not in text('home/.pi/agent/skills/implement/SKILL.md')
assert not (r/'home/.pi/agent/extensions/parallel-review.ts').exists()
for name in ['standards','spec']:
 body=text(f'home/.pi/agent/agents/{name}.md')
 tools=re.search(r'^tools: (.+)$',body,re.M).group(1)
 assert set(tools.split(', '))=={'read','grep','find','ls'}
 assert not re.search(r'^model:',body,re.M)
assert 'Smell baseline' in text('home/.pi/agent/agents/standards.md')
for p in (r/'skills').glob('*/SKILL.md'):
 assert p.stat().st_size<=10240,p
print('PASS review workflow contracts')
PY
if ! command -v npm >/dev/null 2>&1; then
 printf 'SKIP subagent registration (npm unavailable)\n'
 exit 0
fi
package="$(npm root -g)/@earendil-works/pi-coding-agent"
if [ ! -f "$package/examples/extensions/subagent/index.ts" ]; then
 printf 'SKIP subagent registration (installed Pi example unavailable)\n'
 exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
HOME="$tmp" PI_CODING_AGENT_DIR="$tmp/.pi/agent" PI_PACKAGE="$package" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const root=process.env.PI_PACKAGE;
const {loadExtensions}=await import(pathToFileURL(`${root}/dist/core/extensions/loader.js`));
const result=await loadExtensions([`${root}/examples/extensions/subagent/index.ts`],process.env.HOME);
assert.deepEqual(result.errors,[]);
assert.equal(result.extensions.length,1);
assert.ok(result.extensions[0].tools.has('subagent'));
console.log('PASS installed Pi subagent registration (no model invocation)');
JS
