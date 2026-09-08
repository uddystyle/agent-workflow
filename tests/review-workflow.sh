#!/usr/bin/env bash
# skill の配信契約まで。モデルや Herdr pane は起動しない。
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
REPO="$repo" python3 - <<'PY'
from pathlib import Path
import os,re
r=Path(os.environ['REPO'])
def text(p): return (r/p).read_text()
review=text('skills/code-review/SKILL.md')
assert 'name: code-review' in review
assert 'herdr pane split' in review
assert '.result.pane.pane_id' in review
assert 'herdr pane process-info' in review
assert 'shell_pid' in review and 'foreground_processes' in review and 'agent_pane_busy' in review
assert 'foreground_is_shell' not in review
assert '100ms' in review and '最大30秒' in review
assert 'herdr agent start standards' in review
assert 'herdr agent start spec' in review
assert 'herdr agent prompt standards' in review
assert 'herdr agent prompt spec' in review
assert 'PI_PROVIDER' in review and 'PI_MODEL' in review and 'PI_REASONING_LEVEL' in review
assert '新しいtab' in review and '作らない' in review
assert 'subagent:' not in review and 'agentScope:' not in review
assert 'snapshot' in review and '未コミット' in review
assert '仕様なし' in review and '未評価' in review
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
print('PASS Herdr pane review workflow contracts')
PY
