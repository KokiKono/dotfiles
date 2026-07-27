#!/usr/bin/env bats

load ../test_helper

# git worktree / branch クリーンアップ関数（zsh）の構文と関数定義を検証する。
# 対話・fzf 実行はテストしない（構文チェックと関数が定義されることのみ）。

FILE="home/dot_config/zsh/git-worktree.zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
}

@test "git-worktree.zsh: valid zsh syntax" {
    run zsh -n "${REPO_ROOT}/${FILE}"
    [ "$status" -eq 0 ]
}

@test "git-worktree.zsh: sourcing defines wrm / brm / bd / helper" {
    run zsh -c "source '${REPO_ROOT}/${FILE}'; typeset -f wrm brm bd __gwt_main_branch >/dev/null && echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
