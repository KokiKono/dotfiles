#!/usr/bin/env bats

load ../test_helper

# CLAUDE.md に注意書きとして書いていた落とし穴を、文章ではなく検査で防ぐ。
# 検出の正規表現が壊れると違反 0 件で黙って通るので、悪い例を検出できることも併せて確かめる。

# 行全体が [[ ... ]] で、|| false が付いていない行を出す。
# macOS の bash では errexit が [[ ]] の失敗で止まらず、テストの途中の assertion が素通りする。
bare_double_brackets() {
    grep -nE '^[[:space:]]*\[\[.*\]\][[:space:]]*$' "$@"
}

# zsh の path / fpath / cdpath / manpath / module_path は PATH などと連動する特殊変数。
# ローカル変数に使うと PATH が書き換わり、以降のコマンドが command not found になる。
zsh_special_path_vars() {
    grep -nE '\b(local|typeset|declare|integer|readonly)\b[^#]*[[:space:]](path|fpath|cdpath|manpath|module_path)([[:space:]=]|$)|\bfor[[:space:]]+(path|fpath|cdpath|manpath|module_path)[[:space:]]+in\b|(^|[;&|[:space:]])(path|fpath|cdpath|manpath|module_path)=' "$@"
}

zsh_sources() {
    find "${REPO_ROOT}/home" -type f \( -name '*.zsh' -o -name 'dot_zshrc' -o -name 'dot_zprofile' -o -name 'dot_zshenv' \)
}

@test "lint: detectors catch the known bad patterns" {
    bad="${BATS_TEST_TMPDIR}/bad"
    printf '    [[ "$output" == *x* ]]\n    [[ -n "$a" ]] || false\n' >"$bad.bats"
    [ "$(bare_double_brackets "$bad.bats" | wc -l | tr -d ' ')" -eq 1 ]

    printf '%s\n' 'local path="$1"' 'local repo path' 'for path in a b; do' 'path=/tmp' \
        'local file_path="$1"' 'echo $path' 'local p="$path"' >"$bad.zsh"
    [ "$(zsh_special_path_vars "$bad.zsh" | wc -l | tr -d ' ')" -eq 4 ]
}

@test "lint: bats assertions written as a bare [[ ]] line end with || false" {
    run bare_double_brackets -r --include='*.bats' "${REPO_ROOT}/tests"
    # grep は見つからないとき 1、エラーのとき 2 を返す。2 で通さない
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "lint: zsh sources never assign zsh's special path arrays" {
    files="$(zsh_sources)"
    [ -n "$files" ]
    # shellcheck disable=SC2086
    run zsh_special_path_vars $files
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}
