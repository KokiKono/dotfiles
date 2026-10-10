#!/usr/bin/env bats

load ../test_helper

PLUGIN="home/dot_config/herdr/plugins/git-diff"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    PICK="${REPO_ROOT}/${PLUGIN}/executable_pick.zsh"
    FILES="${REPO_ROOT}/${PLUGIN}/executable_files.zsh"
    SHOW="${REPO_ROOT}/${PLUGIN}/executable_show.zsh"
    LIB="${REPO_ROOT}/${PLUGIN}/lib.zsh"
}

# base（origin/main）から 1 コミット進み、未コミットと未追跡もあるリポジトリを作る。
# origin は実在しないので refs/remotes/origin/main を手で置く。
make_repo() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q -b main
    git -C "${REPO}" config user.email t@example.com
    git -C "${REPO}" config user.name tester
    git -C "${REPO}" config commit.gpgsign false
    printf 'a\nb\nc\n' >"${REPO}/keep.txt"
    printf 'old\n' >"${REPO}/renamed.txt"
    printf 'x\n' >"${REPO}/gone.txt"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -qm init
    git -C "${REPO}" update-ref refs/remotes/origin/main HEAD
    git -C "${REPO}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    git -C "${REPO}" checkout -qb feature
    printf 'a\nB\nc\nd\n' >"${REPO}/keep.txt"
    git -C "${REPO}" mv renamed.txt renamed2.txt
    git -C "${REPO}" rm -q gone.txt
    printf 'committed\n' >"${REPO}/added.txt"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -qm work
    # ここから下はコミットしない（● が付く側）
    printf 'a\nB\nc\nd\ne\n' >"${REPO}/keep.txt"
    printf 'untracked\nfile\n' >"${REPO}/brand-new.txt"
    export GIT_DIFF_REPO="${REPO}"
}

# ANSI を落として読みやすくする
plain() { printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

@test "pick.zsh / files.zsh / show.zsh / lib.zsh: valid zsh syntax" {
    for f in "${PICK}" "${FILES}" "${SHOW}" "${LIB}"; do
        run zsh -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "files.zsh: lists committed and uncommitted changes with marks" {
    make_repo
    run zsh "${FILES}"
    [ "$status" -eq 0 ]
    out="$(plain "$output")"
    # コミット済みだけのものは ○、未コミットを含むものは ●
    [[ "$out" == *"○ added.txt"* ]] || false
    [[ "$out" == *"● keep.txt"* ]] || false
    # 未追跡も PR に載る前提で並べる
    [[ "$out" == *"● brand-new.txt"* ]] || false
    # 削除も出る
    [[ "$out" == *"D"*"gone.txt"* ]] || false
}

@test "files.zsh: emits path in column 1 and the rename source in column 3" {
    make_repo
    run zsh "${FILES}"
    [ "$status" -eq 0 ]
    out="$(plain "$output")"
    line="$(printf '%s\n' "$out" | grep '^renamed2.txt	')"
    [ -n "$line" ]
    # 3 列目は rename の旧パス。show.zsh に両方渡さないと rename として検出されない
    [ "$(printf '%s' "$line" | cut -f3)" = "renamed.txt" ]
    # rename 以外の 3 列目は空
    [ -z "$(printf '%s\n' "$out" | grep '^keep.txt	' | cut -f3)" ]
}

@test "files.zsh: counts lines added and removed against the merge base" {
    make_repo
    run zsh "${FILES}"
    out="$(plain "$output")"
    # base から見て keep.txt は 3 行足して 1 行消している（未コミット分を含む）
    [[ "$(printf '%s\n' "$out" | grep '^keep.txt	')" == *"+3 -1"* ]] || false
}

@test "files.zsh: aligns the path column" {
    make_repo
    run zsh "${FILES}"
    out="$(plain "$output")"
    a="$(printf '%s\n' "$out" | grep '^keep.txt	' | cut -f2)"
    b="$(printf '%s\n' "$out" | grep '^brand-new.txt	' | cut -f2)"
    # 行数カウントの開始位置（+ の手前）が揃っていること
    pa="${a%%+*}"
    pb="${b%%+*}"
    [ "${#pa}" -eq "${#pb}" ]
}

@test "files.zsh: feeds awk newline-delimited records, never NUL" {
    # macOS の awk は RS=\"\\0\" を扱えず最初のレコードしか読まない。-z の出力を
    # そのまま awk に渡すと一覧が 1 件に化けるので、間に tr を挟んでいること。
    run grep -c "tr '\\\\0' '\\\\n' | awk" "${FILES}"
    [ "$status" -eq 0 ]
    [ "$output" -ge 2 ]
}

@test "files.zsh: uses no variable named path" {
    # zsh の \$path は PATH と連動する特殊変数。ローカル変数に使うと PATH が壊れ、
    # 以降の tr / wc が command not found になる。
    run grep -nE '(^|[^A-Za-z_])path=|read -r .*\bpath\b|typeset .*\bpath\b' "${FILES}" "${SHOW}" "${LIB}"
    [ "$status" -ne 0 ]
}

@test "show.zsh: renders a rename as a rename when given both paths" {
    command -v delta >/dev/null 2>&1 || skip "delta not installed"
    make_repo
    run zsh "${SHOW}" renamed2.txt renamed.txt
    [ "$status" -eq 0 ]
    out="$(plain "$output")"
    [[ "$out" == *"renamed"*"renamed.txt"*"renamed2.txt"* ]] || false
    # 旧パスを渡さないと中身が丸ごと追加されたように見える
    [[ "$out" != *"old"* ]] || false
}

@test "show.zsh: renders an untracked file against an empty file" {
    command -v delta >/dev/null 2>&1 || skip "delta not installed"
    make_repo
    run zsh "${SHOW}" brand-new.txt
    [ "$status" -eq 0 ]
    out="$(plain "$output")"
    [[ "$out" == *"untracked"* ]] || false
    [[ "$out" == *"file"* ]] || false
}

@test "show.zsh: renders a deleted file instead of looking for it on disk" {
    command -v delta >/dev/null 2>&1 || skip "delta not installed"
    make_repo
    run zsh "${SHOW}" gone.txt
    [ "$status" -eq 0 ]
    out="$(plain "$output")"
    [[ "$out" == *"gone.txt"* ]] || false
    [[ "$out" == *"x"* ]] || false
}

@test "show.zsh: side by side, and the width comes from fzf" {
    grep -q -- '--side-by-side' "${SHOW}"
    grep -q 'FZF_PREVIEW_COLUMNS' "${SHOW}"
}

@test "files.zsh: says so instead of guessing when there is no repo" {
    run env GIT_DIFF_REPO="${BATS_TEST_TMPDIR}" GD_FAIL_WAIT=0 \
        zsh -c "cd ${BATS_TEST_TMPDIR} && exec zsh ${FILES}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"git リポジトリ"* ]] || false
}

@test "pick.zsh: no --bind payload contains a comma" {
    # fzf の --bind はコンマでバインドを区切るので、reload() / execute() の中に
    # コンマがあると起動時に rc=2 で即死する（popup が一瞬開いて閉じる）。
    run grep -o -- '--bind="[^"]*"' "${PICK}"
    [ "$status" -eq 0 ]
    while read -r bind; do
        payload="${bind#*(}"
        [ "${payload}" = "${bind}" ] && continue
        payload="${payload%)\"}"
        [[ "${payload}" != *,* ]] || {
            echo "--bind にコンマが入っている: ${bind}" >&2
            false
        }
    done <<<"$output"
}

@test "pick.zsh: pins the repo so the preview cannot drift to another one" {
    # 一覧と preview は別プロセス。フォーカスは popup を開いた時点のものなので、
    # 解決済みのリポジトリを子へ渡していること
    grep -q 'export GIT_DIFF_REPO' "${PICK}"
}

@test "pick.zsh: hands show.zsh both the path and the rename source" {
    grep -q -- '--preview="${(q)show} {1} {3}"' "${PICK}"
    grep -q -- 'enter:execute(${(q)show} {1} {3} --pager)' "${PICK}"
}

@test "pick.zsh: keeps fzf filtering on" {
    # hello-run と違って候補が数十件になるので、絞り込みは切らない
    run grep -- '--disabled' "${PICK}"
    [ "$status" -ne 0 ]
}

@test "herdr-plugin.toml: opens as a popup and launches pick.zsh" {
    command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
    run python3 -c "
import sys, tomllib
m = tomllib.load(open(sys.argv[1], 'rb'))
pane = m['panes'][0]
assert m['id'] == 'kokikono.git-diff', m['id']
assert pane['id'] == 'files', pane['id']
assert pane['placement'] == 'popup', pane['placement']
assert pane['command'][-1] == 'pick.zsh', pane['command']
assert '-l' in pane['command'], pane['command']
" "${REPO_ROOT}/${PLUGIN}/herdr-plugin.toml"
    [ "$status" -eq 0 ]
}

@test "lib.zsh: takes the repo from the plugin context json" {
    # popup は元のペインの cwd を引き継がない。herdr が渡してくる context に
    # 開いた時点のフォーカス中ペインの cwd が入っているので、まずそれを見る
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    make_repo
    ctx="{\"focused_pane_cwd\":\"${REPO}\",\"workspace_cwd\":\"/nonexistent\"}"
    run env -u GIT_DIFF_REPO HERDR_PLUGIN_CONTEXT_JSON="${ctx}" \
        zsh -c "source '${LIB}'; gd_repo_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "${REPO}" && pwd -P)" ]
}

@test "lib.zsh: skips context paths that are not git repositories" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    make_repo
    ctx="{\"focused_pane_cwd\":\"${BATS_TEST_TMPDIR}\",\"workspace_cwd\":\"${REPO}\"}"
    run env -u GIT_DIFF_REPO HERDR_PLUGIN_CONTEXT_JSON="${ctx}" \
        zsh -c "source '${LIB}'; gd_repo_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "${REPO}" && pwd -P)" ]
}
