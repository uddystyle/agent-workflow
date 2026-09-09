#!/usr/bin/env bash
# review skillと配信契約まで。sub-agentは起動しない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" python3 - <<'PY'
from pathlib import Path
import os
r=Path(os.environ['REPO'])
def text(p): return (r/p).read_text()
review=text('skills/code-review/SKILL.md')
assert 'name: code-review' in review
assert 'disable-model-invocation: true' in review
assert 'parallel sub-agents' in review
assert '追加のsub-agentへ委譲しない' in review
assert 'Mysterious Name' in review and 'Refused Bequest' in review
assert '足りない' in review and '余分' in review
assert 'snapshot' in review and '未コミット' in review
assert '仕様なし' in review and '未評価' in review
assert 'herdr ' not in review.lower()
assert 'pane' not in review.lower() and 'tab' not in review.lower()
assert 'PI_PROVIDER' not in review and 'PI_MODEL' not in review and 'PI_REASONING_LEVEL' not in review
research=text('skills/research/SKILL.md')
assert 'RESEARCH_SUBAGENT=1' in research
assert 'herdr pane split' in research
assert '.result.pane.pane_id' in research
assert 'herdr pane process-info' in research
assert 'shell_pid' in research and 'foreground_processes' in research and 'agent_pane_busy' in research
assert 'foreground_is_shell' not in research
assert '100ms' in research and '最大30秒' in research
assert 'herdr agent start research' in research
assert 'herdr agent wait' in research
assert research.index('herdr agent wait') < research.index('herdr agent get') < research.index('herdr agent read')
assert '追加のagentやpaneを作らず' in research
assert not (r/'home/.pi/agent/skills/research/SKILL.md').exists()
alias=text('skills/two-axis-review/SKILL.md')
assert 'disable-model-invocation: true' in alias
assert '../code-review/SKILL.md' in alias
assert 'disable-model-invocation: true' not in text('skills/worktrees/SKILL.md')
standards=text('skills/coding-standards/SKILL.md')
assert 'provenance' in standards
assert 'type-aware' in standards
assert 'invocation' in standards
assert '結果不明' in standards and 'compensation' in standards
assert 'public interface' in standards and 'compile-time' in standards
herdr=text('skills/herdr/SKILL.md')
assert 'another skill explicitly asks for or requires them' in herdr
assert 'Start and coordinate an agent' in herdr
plannotator=text('skills/plannotator-tui/SKILL.md')
assert 'name: plannotator-tui' in plannotator
assert 'disable-model-invocation: true' in plannotator
tdd=text('home/.pi/agent/skills/tdd/SKILL.md')
assert 'disable-model-invocation: true' in tdd
assert 'disable-model-invocation: true' not in text('skills/writing-for-agents/SKILL.md')
domain=text('home/.pi/agent/skills/domain-modeling/SKILL.md')
assert '## 4. 判断' not in domain
grill=text('home/.pi/agent/skills/grill-with-docs/SKILL.md')
assert 'ADR' not in grill and '判断' not in grill
assert 'HERDR_ENV=1' in plannotator
assert 'plannotator-tui herdr open' in plannotator
assert 'End your turn' in plannotator
assert 'file://' in plannotator
assert 'MIT License' in text('skills/plannotator-tui/LICENSE')
assert not (r/'home/.pi/agent/skills/implement/SKILL.md').exists()
assert not (r/'skills/cua-driver').exists()
assert not (r/'skills/computer-use-mcp').exists()
assert not (r/'home/.pi/agent/extensions/parallel-review.ts').exists()
assert not (r/'home/.pi/agent/agents/standards.md').exists()
assert not (r/'home/.pi/agent/agents/spec.md').exists()
for p in (r/'skills').glob('*/SKILL.md'):
 if p.parent.name != 'herdr':
  assert p.stat().st_size<=10240,p
print('PASS parallel review workflow contracts')
PY
