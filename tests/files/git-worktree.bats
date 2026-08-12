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
    run zsh -c "source '${REPO_ROOT}/${FILE}'; typeset -f wrm brm bd __gwt_main_branch __gwt_remove_worktrees __gwt_retry_force >/dev/null && echo OK"
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

# 削除ループは [n/N] の進捗行と末尾の集計を出す（対話経路なので書式の存在で固定する）。
@test "git-worktree.zsh: wrm prints per-item progress and a summary" {
    grep -q '\[%d/%d\]' "${REPO_ROOT}/${FILE}"
    grep -q '削除 %d 件 / 失敗 %d 件' "${REPO_ROOT}/${FILE}"
}

# 未コミットの変更で失敗した worktree は __gwt_failed に残り、--force で消し直せる。
@test "git-worktree.zsh: __gwt_remove_worktrees reports progress and keeps failures for retry" {
    repo="${BATS_TEST_TMPDIR}/repo"
    git init -q "$repo"
    git -C "$repo" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
    git -C "$repo" branch clean-wt
    git -C "$repo" branch dirty-wt
    git -C "$repo" worktree add -q "${BATS_TEST_TMPDIR}/wt-clean" clean-wt
    git -C "$repo" worktree add -q "${BATS_TEST_TMPDIR}/wt-dirty" dirty-wt
    echo dirty > "${BATS_TEST_TMPDIR}/wt-dirty/untracked.txt"

    run zsh -c "cd '$repo'; source '${REPO_ROOT}/${FILE}'
        __gwt_remove_worktrees 0 \
          '${BATS_TEST_TMPDIR}/wt-clean'\$'\t'clean-wt \
          '${BATS_TEST_TMPDIR}/wt-dirty'\$'\t'dirty-wt
        echo \"rc=\$?\"; echo \"failed=\${#__gwt_failed[@]}\""
    [[ "$output" == *"[1/2]"* ]]
    [[ "$output" == *"[2/2]"* ]]
    [[ "$output" == *"削除 1 件 / 失敗 1 件 (計 2 件)"* ]]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"failed=1"* ]]
    [ ! -d "${BATS_TEST_TMPDIR}/wt-clean" ]

    # 失敗分を --force で削除し直せる
    run zsh -c "cd '$repo'; source '${REPO_ROOT}/${FILE}'
        __gwt_remove_worktrees 1 '${BATS_TEST_TMPDIR}/wt-dirty'\$'\t'dirty-wt; echo \"rc=\$?\""
    [[ "$output" == *"削除 1 件 / 失敗 0 件 (計 1 件)"* ]]
    [[ "$output" == *"rc=0"* ]]
    [ ! -d "${BATS_TEST_TMPDIR}/wt-dirty" ]
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
