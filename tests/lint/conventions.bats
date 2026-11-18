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

# zsh の path などは PATH などと連動する特殊変数。ローカル変数として使うと PATH が書き換わり、
# 以降のコマンドが command not found になる。起動ファイルでの PATH の編集
# （typeset -U path、自分を参照する path=(... $path)）とコメント行は通す。
zsh_special_path_vars() {
    local v='(path|fpath|cdpath|manpath|module_path|mailpath|psvar)' id='[A-Za-z_][A-Za-z0-9_]*' st
    grep -HnE "\b(local|read|typeset|declare|integer|private)\b[^#;|&]*[[:space:]]$v([[:space:]=]|\$)|(^|[^-.A-Za-z0-9_\$])$v=|\b(for|foreach)([[:space:]]+$id)*[[:space:]]+$v([[:space:]]+$id)*[[:space:]]*(\(|in\b)|-v[[:space:]]+$v\b" "$@" \
        | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#|\btypeset[[:space:]]+-[A-Za-z]*U[A-Za-z]*[[:space:]]+$v[[:space:]]*\$|$v=\(.*\\$\{?$v\b"
    st=("${PIPESTATUS[@]}")
    # 前の grep のエラー（2）を後ろの grep -v の 1 で隠さない
    [ "${st[0]}" -le 1 ] || return 2
    return "${st[1]}"
}

# grep は見つからないとき 1、エラーのとき 2 を返す。2 で通さない
assert_no_hits() {
    [ "$status" -eq 1 ] || { echo "$output"; false; }
}

# 当たった行の行番号を空白区切りで出す
hit_lines() {
    printf '%s\n' "${lines[@]}" | sed -E 's/^([^:]+:)?([0-9]+):.*/\2/' | tr '\n' ' ' | sed 's/ $//'
}

@test "lint: detectors catch the known bad patterns and only those" {
    bad="${BATS_TEST_TMPDIR}/bad"
    printf '%s\n' '    [[ "$output" == *x* ]]' '    [[ -n "$a" ]] || false' '    [[ a ]] # c' '    [[ a ]];' \
        '    ! [[ a ]]' '    [[ a ]] && b' >"$bad.bats"
    run bare_double_brackets "$bad.bats"
    [ "$(hit_lines)" = "1 3 4 5" ]

    printf '%s\n' 'local path="$1"' 'local repo path' 'for path in a b; do' 'path=/tmp' 'read -r st path' \
        'for k path in x; do' 'printf -v path %s x' 'x=$(path=$1; echo)' 'typeset -a path' \
        'for path ($files); do' 'path=("$1" "$2")' 'local mailpath' \
        'local file_path="$1"' 'echo $path' 'local p="$path"' 'typeset -U path' \
        'path=(/opt/bin $path)' 'fpath=(~/.zfunc $fpath)' '  # local path は使わない' \
        'wt --config-set "worktree-path=x"' 'local msg; msg="see path here"' >"$bad.zsh"
    run zsh_special_path_vars "$bad.zsh"
    [ "$(hit_lines)" = "1 2 3 4 5 6 7 8 9 10 11 12" ]
}

@test "lint: a grep error is not reported as no hits" {
    run zsh_special_path_vars "${BATS_TEST_TMPDIR}/does-not-exist"
    [ "$status" -eq 2 ]
}

@test "lint: bats assertions written as a bare [[ ]] line end with || false" {
    run bare_double_brackets -r --include='*.bats' "${REPO_ROOT}/tests"
    assert_no_hits
}

@test "lint: zsh sources never use zsh's special path arrays as local variables" {
    run zsh_special_path_vars -r --include='*.zsh' --include='*.zsh.tmpl' --include='dot_z*' "${REPO_ROOT}/home"
    assert_no_hits
}
