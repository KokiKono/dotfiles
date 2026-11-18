#!/usr/bin/env bats

load ../test_helper

# CLAUDE.md に注意書きとして書いていた落とし穴を、文章ではなく検査で防ぐ。
# 検出の正規表現が壊れると違反 0 件で黙って通るので、悪い例を検出できることも併せて確かめる。

# 行全体が [[ ... ]] で、|| false が付いていない行を出す。
# macOS の bash では errexit が [[ ]] の失敗で止まらず、テストの途中の assertion が素通りする。
bare_double_brackets() {
    grep -nE '^[[:space:]]*\[\[.*\]\][[:space:]]*$' "$@"
}

# zsh の path などは PATH と連動する特殊変数。ローカル変数に使うと PATH が書き換わり、
# 以降のコマンドが command not found になる。
zsh_special_path_vars() {
    local v='(path|fpath|cdpath|manpath|module_path)'
    grep -nE "\b(local|typeset|declare|integer|readonly|read)\b[^#]*[[:space:]]$v([[:space:]=]|\$)|\bfor[[:space:]]+$v[[:space:]]+in\b|(^|[;&|[:space:]])$v=" "$@"
}

# grep は見つからないとき 1、エラーのとき 2 を返す。2 で通さない
assert_no_hits() {
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "lint: detectors catch the known bad patterns" {
    bad="${BATS_TEST_TMPDIR}/bad"
    printf '    [[ "$output" == *x* ]]\n    [[ -n "$a" ]] || false\n' >"$bad.bats"
    run bare_double_brackets "$bad.bats"
    [ "${#lines[@]}" -eq 1 ]

    printf '%s\n' 'local path="$1"' 'local repo path' 'for path in a b; do' 'path=/tmp' 'read -r st path' \
        'local file_path="$1"' 'echo $path' 'local p="$path"' >"$bad.zsh"
    run zsh_special_path_vars "$bad.zsh"
    [ "${#lines[@]}" -eq 5 ]
}

@test "lint: bats assertions written as a bare [[ ]] line end with || false" {
    run bare_double_brackets -r --include='*.bats' "${REPO_ROOT}/tests"
    assert_no_hits
}

@test "lint: zsh sources never assign zsh's special path arrays" {
    run zsh_special_path_vars -r --include='*.zsh' --include='dot_z*' "${REPO_ROOT}/home"
    assert_no_hits
}
