#!/usr/bin/env bash
# 書き出す瞬間に、秘密の形をした値を止める（DECISIONS.md D-18）。
#
# 🔴 値を絶対に出さない。出すのは名前と行番号だけ。
#    エラーは端末・ログ・通知を経由して伝播する。検出器がそこから漏らしたら本末転倒である。
#
# 🔴 fail-closed。表が無い・壊れている・入力が読めないときは止める。
#    走査できないものを通してはいけない。
set -uo pipefail

patterns="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-patterns"

deny() {
	printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$1"
	exit 0
}

command -v python3 >/dev/null 2>&1 || deny '"秘密の走査ができない（python3 が無い）。走査できないものは通さない"'
[ -r "$patterns" ] || deny '"秘密の表が読めない。走査できないものは通さない"'

# 🔴 入力を先にファイルへ落とす。
# python3 - <<'PY' はスクリプト自体を stdin から読むので、
# 入力を stdin のまま渡すと python 側からは読めない。
input_file=$(mktemp "${TMPDIR:-/tmp}/secret-scan.XXXXXX") || deny '"一時ファイルが作れない。走査できないものは通さない"'
trap 'rm -f "$input_file"' EXIT HUP INT TERM
cat >"$input_file" 2>/dev/null || true

SECRET_PATTERNS="$patterns" SECRET_INPUT="$input_file" python3 - <<'PY'
import json, os, sys

BASE64URL = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
KINDS = {"prefix", "assignment"}

def deny(reason):
    # ⚠️ 区切りを詰める。bash 側の deny と同じ形にしないと、
    # 受け取る側（検査も含む）が片方にしか当たらない。
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, ensure_ascii=False, separators=(",", ":")))
    sys.exit(0)

def allow():
    sys.exit(0)

# 表を読む。壊れていれば止める。
rows = []
try:
    for raw in open(os.environ["SECRET_PATTERNS"], encoding="utf-8"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 4:
            deny("秘密の表の形が壊れている。走査できないものは通さない")
        label, kind, pattern, min_len = parts
        if kind not in KINDS or not pattern:
            deny("秘密の表に知らない種別がある。走査できないものは通さない")
        rows.append((label, kind, pattern, int(min_len)))
except SystemExit:
    raise
except Exception:
    deny("秘密の表が読めない。走査できないものは通さない")

if not rows:
    deny("秘密の表が空である。走査できないものは通さない")

try:
    with open(os.environ["SECRET_INPUT"], encoding="utf-8") as f:
        payload = json.load(f)
except Exception:
    deny("入力が読めない。走査できないものは通さない")

# 書き出す道具だけを見る。読む道具は漏れではない。
# ⚠️ ここに無い道具は素通りする。書き出す道具が増えたら、ここに足す。
FIELDS = {"Write": "content", "Edit": "new_string", "Bash": "command"}
field = FIELDS.get(payload.get("tool_name", ""))
if field is None:
    allow()

text = (payload.get("tool_input") or {}).get(field)
if not isinstance(text, str) or not text:
    allow()

def run_len(s, i, allowed):
    n = 0
    while i + n < len(s) and (s[i + n] in allowed if allowed else not s[i + n].isspace()):
        n += 1
    return n

hits = []
for label, kind, pattern, min_len in rows:
    start = 0
    while True:
        i = text.find(pattern, start)
        if i < 0:
            break
        start = i + 1
        j = i + len(pattern)
        if kind == "prefix":
            ok = run_len(text, j, BASE64URL) >= min_len
        else:
            while j < len(text) and text[j] in " \t":
                j += 1
            if j >= len(text) or text[j] not in "=:":
                continue
            j += 1
            while j < len(text) and text[j] in " \t":
                j += 1
            ok = run_len(text, j, None) >= min_len
        if ok:
            hits.append((text.count("\n", 0, i) + 1, label))

if not hits:
    allow()

# 🔴 値は出さない。名前と行番号だけ。
seen, lines = set(), []
for line_no, label in sorted(set(hits)):
    if (line_no, label) not in seen:
        seen.add((line_no, label))
        lines.append(f"  行 {line_no}  {label}")

deny(
    "秘密の形をした値が含まれています。\n"
    + "\n".join(lines)
    + "\n\n次の一手:\n"
    "  1. 値を消し、`sk_live_…（伏せた）` のように形だけ残す\n"
    "  2. 同じ操作をやり直す\n"
    "  ⚠️ すでに commit していれば push しない。人に申告する\n"
    "  ⚠️ 誤検知だと判断したら、値を伏せて進め、止められた回数を数える"
)
PY
