#!/usr/bin/env bats

load ../test_helper

# CLAUDE.md に注意書きとして書いていた落とし穴を、文章ではなく検査で防ぐ。
# 検出の正規表現が壊れると違反 0 件で黙って通るので、悪い例を検出できることも併せて確かめる。

# 行全体が [[ ... ]] で、|| false が付いていない行を出す（後ろのコメントや ;、先頭の ! も含む）。
# macOS の bash では errexit が [[ ]] の失敗で止まらず、テストの途中の assertion が素通りする。
# 複数行にまたがる [[ ]] は grep では追えないので見ない。
bare_double_brackets() {
    grep -nE '^[[:space:]]*(![[:space:]]*)?\[\[.*\]\][[:space:]]*;?[[:space:]]*(#.*)?$' "$@"
}

# zsh の path などは PATH と連動する特殊変数。ローカル変数として使うと PATH が書き換わり、
# 以降のコマンドが command not found になる。見るのはローカル変数としての使い方
# （local / read / for / printf -v / 文字列の代入）だけで、typeset -U path や
# path=(... $path) のような PATH の編集は通す。コメント行は除く。
zsh_special_path_vars() {
    local v='(path|fpath|cdpath|manpath|module_path)' id='[A-Za-z_][A-Za-z0-9_]*'
    grep -HnE "\b(local|read)\b[^#]*[[:space:]]$v([[:space:]=]|\$)|(^|[^-.A-Za-z0-9_\$])$v=([^(]|\$)|\bfor([[:space:]]+$id)*[[:space:]]+$v([[:space:]]+$id)*[[:space:]]+in\b|-v[[:space:]]+$v\b" "$@" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

# grep は見つからないとき 1、エラーのとき 2 を返す。2 で通さない
assert_no_hits() {
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "lint: detectors catch the known bad patterns" {
    bad="${BATS_TEST_TMPDIR}/bad"
    printf '%s\n' '    [[ "$output" == *x* ]]' '    [[ -n "$a" ]] || false' '    [[ a ]] # c' '    [[ a ]];' \
        '    ! [[ a ]]' '    [[ a ]] && b' >"$bad.bats"
    run bare_double_brackets "$bad.bats"
    [ "${#lines[@]}" -eq 4 ]

    printf '%s\n' 'local path="$1"' 'local repo path' 'for path in a b; do' 'path=/tmp' 'read -r st path' \
        'for k path in x; do' 'printf -v path %s x' 'x=$(path=$1; echo)' >"$bad.zsh"
    run zsh_special_path_vars "$bad.zsh"
    [ "${#lines[@]}" -eq 8 ]

    printf '%s\n' 'local file_path="$1"' 'echo $path' 'local p="$path"' 'typeset -U path' \
        'path=(/opt/bin $path)' 'fpath=(~/.zfunc $fpath)' '  # local path は使わない' \
        'wt --config-set "worktree-path=x"' >"$bad.ok.zsh"
    run zsh_special_path_vars "$bad.ok.zsh"
    assert_no_hits
}

@test "lint: bats assertions written as a bare [[ ]] line end with || false" {
    run bare_double_brackets -r --include='*.bats' "${REPO_ROOT}/tests"
    assert_no_hits
}

@test "lint: zsh sources never use zsh's special path arrays as local variables" {
    run zsh_special_path_vars -r --include='*.zsh' --include='*.zsh.tmpl' --include='dot_z*' "${REPO_ROOT}/home"
    assert_no_hits
}
