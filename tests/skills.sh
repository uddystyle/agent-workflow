#!/usr/bin/env bash
# 残すskillの契約と、退役skillを復元しない境界を検査する。agentは起動しない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" python3 - <<'PY'
from pathlib import Path
import os
r = Path(os.environ['REPO'])
def text(p): return (r / p).read_text()
retired = ['code-review', 'coding-standards', 'domain-modeling', 'grill-me',
           'grill-with-docs', 'grilling', 'prototype', 'research', 'tdd',
           'cloudflare-composition-root', 'two-axis-review', 'supabase-migrations']
for name in retired:
    assert not (r / 'home/.agents/skills' / name).exists(), name
    for doc in ['AGENTS.md', 'README.md']:
        assert f'/skill:{name}' not in text(doc)
        assert f'home/.agents/skills/{name}/' not in text(doc)
assert not (r / 'home/.pi/agent/skills').exists()
assert 'disable-model-invocation: true' not in text('home/.agents/skills/worktrees/SKILL.md')
herdr = text('home/.agents/skills/herdr/SKILL.md')
assert 'another skill explicitly asks for or requires them' in herdr
assert 'Start and coordinate an agent' in herdr
assert 'Default to a new tab in the current workspace' in herdr
assert 'herdr tab create' in herdr and 'herdr tab close' in herdr
assert 'only when the user explicitly requests a split' in herdr
plannotator = text('home/.agents/skills/plannotator-tui/SKILL.md')
assert 'name: plannotator-tui' in plannotator
assert 'disable-model-invocation: true' in plannotator
assert 'HERDR_ENV=1' in plannotator
assert 'plannotator-tui herdr open' in plannotator
assert 'End your turn' in plannotator
assert 'file://' in plannotator
assert 'MIT License' in text('home/.agents/skills/plannotator-tui/LICENSE')
writing = text('home/.agents/skills/writing-for-agents/SKILL.md')
mechanics = text('home/.agents/skills/writing-for-agents/SKILL-MECHANICS.md')
assert 'disable-model-invocation: true' not in writing
assert 'SKILL-MECHANICS.md' in writing
assert 'model-invoked' in mechanics and 'manual-only' in mechanics
assert 'router skill' in mechanics and '共有reference' in mechanics
assert 'disable-model-invocation: true' in text('home/.agents/skills/handoff/SKILL.md')
diagnosing = text('home/.agents/skills/diagnosing-bugs/SKILL.md')
assert 'disable-model-invocation: true' not in diagnosing
assert 'red-capable' in diagnosing and '3–5 ranked hypotheses' in diagnosing
assert 'scripts/hitl-loop.template.sh' in diagnosing and '[DEBUG-' in diagnosing
assert '321658273cb1d20b76026717d027d505790106d4' in text('home/.agents/skills/diagnosing-bugs/SOURCE.md')
assert 'MIT License' in text('home/.agents/skills/diagnosing-bugs/LICENSE')
discoverable = text('home/.agents/skills/write-discoverable-code/SKILL.md')
assert 'disable-model-invocation: true' not in discoverable
assert 'One concept, one spelling' in discoverable and 'Keep strings whole' in discoverable
assert 'edcdedb38a545f67c065f4084b3627517f0d79cf' in text('home/.agents/skills/write-discoverable-code/SOURCE.md')
assert 'MIT License' in text('home/.agents/skills/write-discoverable-code/LICENSE')
for p in ['home/.pi/agent/skills/implement/SKILL.md', 'home/.agents/skills/cua-driver',
          'home/.agents/skills/computer-use-mcp', 'home/.pi/agent/extensions/parallel-review.ts',
           'home/.pi/agent/extensions/supabase-prod-confirm.ts',
           'home/.pi/agent/agents/standards.md', 'home/.pi/agent/agents/spec.md']:
    assert not (r / p).exists(), p
for p in (r / 'home/.agents/skills').glob('*/SKILL.md'):
    if p.parent.name != 'herdr':
        assert p.stat().st_size <= 10240, p
print('PASS remaining skills and retirement contracts')
PY
bash -n "$repo/home/.agents/skills/diagnosing-bugs/scripts/hitl-loop.template.sh"
