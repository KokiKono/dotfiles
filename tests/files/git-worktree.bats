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

@test "git-worktree.zsh: wrm --help shows force and all flags" {
    run zsh -c "source '${REPO_ROOT}/${FILE}'; wrm --help"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--force"* ]]
    [[ "$output" == *"--all"* ]]
}

@test "git-worktree.zsh: wrm rejects unknown option" {
    run zsh -c "source '${REPO_ROOT}/${FILE}'; wrm --nope"
    [ "$status" -eq 2 ]
}

@test "git-worktree.zsh: wrm queries gh in bulk (no per-worktree gh pr view)" {
    run grep -n 'gh pr view' "${REPO_ROOT}/${FILE}"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# __gwt_pr_states: gh を 1 回だけ叩き、同一ブランチの複数 PR は OPEN を優先する。
@test "git-worktree.zsh: __gwt_pr_states dedupes to OPEN over MERGED" {
    stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/sh\nprintf "feat\\tMERGED\\nfeat\\tOPEN\\nold\\tMERGED\\n"\n' > "$stub/gh"
    chmod +x "$stub/gh"
    run env PATH="$stub:$PATH" zsh -c \
        "source '${REPO_ROOT}/${FILE}'; __gwt_pr_states '${BATS_TEST_TMPDIR}' | sort"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat"$'\t'"OPEN"* ]]
    [[ "$output" != *"feat"$'\t'"MERGED"* ]]
    [[ "$output" == *"old"$'\t'"MERGED"* ]]
}

@test "git-worktree.zsh: __gwt_pr_states fails when gh fails" {
    stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/gh"
    chmod +x "$stub/gh"
    run env PATH="$stub:$PATH" zsh -c \
        "source '${REPO_ROOT}/${FILE}'; __gwt_pr_states '${BATS_TEST_TMPDIR}'"
    [ "$status" -ne 0 ]
}
