#!/usr/bin/env bash
# 秘密の走査が「止めるべきものを止め、通すべきものを通す」かを確かめる。
#
# ⚠️ ここに置く鍵はすべて偽物である。形だけを真似ている。
set -uo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hook="$repo/home/.pi/agent/extensions/secret-scan/secret-scan.sh"
passed=0

fail() {
	printf 'FAIL %s\n' "$*" >&2
	exit 1
}

# 素通りするはず。出力が空であること。
expect_allow() {
	local name=$1 payload=$2 out
	out=$(printf '%s' "$payload" | bash "$hook" 2>&1)
	[ -z "$out" ] || fail "$name: 止めてはいけないものを止めた"
	passed=$((passed + 1))
}

# 止めるはず。deny が返り、🔴 値そのものが出力に含まれないこと。
expect_deny() {
	local name=$1 payload=$2 secret=$3 out
	out=$(printf '%s' "$payload" | bash "$hook" 2>&1)
	[[ $out == *'"permissionDecision":"deny"'* ]] || fail "$name: 止めるべきものを通した"
	[[ $out != *"$secret"* ]] || fail "$name: 🔴 出力に値そのものが混じった"
	[[ $out == *'次の一手'* ]] || fail "$name: 次の一手が無い"
	passed=$((passed + 1))
}

# 🔴 鍵の形をした文字列を、このファイルに連続して置かない。
# 置くと、秘密を検出する仕組みが本物と区別できない——こちらのものも、送り先のものも。
# ⚠️ 実際に一度、これで push が拒否された。組み立ててから使う。
P_STRIPE='sk_live'
P_JWT='eyJ'
FAKE_STRIPE="${P_STRIPE}_51AbCdEfGhIjKlMnOpQrStUvWx"
FAKE_JWT="${P_JWT}hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9AbCdEfGhIjKl"
ASSIGN_UNDER='abcdefghijklmnopqrstuvwxyz0123456789abc'  # 39 文字
ASSIGN_EXACT='abcdefghijklmnopqrstuvwxyz0123456789abcd' # 40 文字
BOUND_UNDER="${P_STRIPE}_AbCdEfGhIjKlMnOpQrStUvW"
BOUND_EXACT="${P_STRIPE}_AbCdEfGhIjKlMnOpQrStUvWx"

# --- 通すべきもの ---
expect_allow '読む道具' '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'
expect_allow '前置詞だけの文章' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"鍵は ${P_STRIPE}_ で始まる\"}}"
expect_allow '代入でない表' '{"tool_name":"Write","tool_input":{"content":"| SUPABASE_SERVICE_ROLE_KEY | 未設定 |"}}'
expect_allow '値が短い代入' '{"tool_name":"Write","tool_input":{"content":"STRIPE_SECRET_KEY: 設定済み"}}'
expect_allow '前置詞に似た語' '{"tool_name":"Write","tool_input":{"content":"re_export した"}}'
expect_allow '空の入力' '{"tool_name":"Write","tool_input":{"content":""}}'
# 🔴 3文字の前置詞を戻させない。`re_` を持っていたとき、この識別子が止められた。
expect_allow '語の途中に前置詞を含む識別子' '{"tool_name":"Write","tool_input":{"content":"create unique index score_mutations_client_mutation_id_key"}}'
# テストの偽物や穴埋めは通す。下限 20 のとき、これが止められていた。
expect_allow 'テストの偽物' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"SUPABASE_SERVICE_ROLE_KEY: 'service_role_dummy'\"}}"

# 🔴 下限が効いていることを確かめる。
# 前置詞だけの文章は「後続0文字」なので、下限を1に緩めても通ってしまう。
# 下限のすぐ下の長さで試さないと、緩められたことに気づけない。
expect_allow '下限の1つ下' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"${BOUND_UNDER}\"}}"
expect_deny '下限ちょうど' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"${BOUND_EXACT}\"}}" "${BOUND_EXACT##*_}"
# 代入の側も同じように挟む。こちらは 20 から 40 へ上げた——下げ戻されたら落ちる。
expect_allow '代入の下限の1つ下' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"SUPABASE_SERVICE_ROLE_KEY=${ASSIGN_UNDER}\"}}"

# --- 止めるべきもの ---
expect_deny 'Write に鍵' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"KEY=$FAKE_STRIPE\"}}" "$FAKE_STRIPE"
expect_deny 'Edit に鍵' "{\"tool_name\":\"Edit\",\"tool_input\":{\"new_string\":\"$FAKE_STRIPE\"}}" "$FAKE_STRIPE"
expect_deny 'Bash に鍵' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo $FAKE_STRIPE\"}}" "$FAKE_STRIPE"
expect_deny 'JWT' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"$FAKE_JWT\"}}" "$FAKE_JWT"
expect_deny '名前で捕まえる' "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"SUPABASE_SERVICE_ROLE_KEY=${ASSIGN_EXACT}\"}}" "$ASSIGN_EXACT"

# --- 走査できないときは止める（fail-closed）---
out=$(printf 'これは JSON ではない' | bash "$hook" 2>&1)
[[ $out == *'"permissionDecision":"deny"'* ]] || fail '壊れた入力を通した'
passed=$((passed + 1))

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$hook" "$tmp/secret-scan.sh"
printf 'label kind\n' >"$tmp/secret-patterns" # 4つ組でない
out=$(printf '{"tool_name":"Write","tool_input":{"content":"x"}}' | bash "$tmp/secret-scan.sh" 2>&1)
[[ $out == *'"permissionDecision":"deny"'* ]] || fail '壊れた表を通した'
passed=$((passed + 1))

rm "$tmp/secret-patterns"
out=$(printf '{"tool_name":"Write","tool_input":{"content":"x"}}' | bash "$tmp/secret-scan.sh" 2>&1)
[[ $out == *'"permissionDecision":"deny"'* ]] || fail '表が無いのに通した'
passed=$((passed + 1))

printf 'PASS %s checks\n' "$passed"
