#!/usr/bin/env bats

load ../test_helper

PLUGIN="home/dot_config/herdr/plugins/skill-create"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    PICK="${REPO_ROOT}/${PLUGIN}/executable_pick.zsh"
    LIB="${REPO_ROOT}/${PLUGIN}/lib.zsh"
    export SKILL_CREATE_HELLO_RUN="${REPO_ROOT}/home/dot_config/zsh/hello-run.zsh"
    export SKILL_CREATE_PROMPT_FILE="${REPO_ROOT}/${PLUGIN}/prompt.md"
}

# lib.zsh を hello-run.zsh と一緒に読み込んで関数を 1 つ呼ぶ
lib() {
    run zsh -c "source '${SKILL_CREATE_HELLO_RUN}'; source '${LIB}'; $*"
}

# origin/master と、マージ済みの skills/foo が残っているリポジトリ
make_repo() {
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q -b master
    git -C "${REPO}" config user.email t@example.com
    git -C "${REPO}" config user.name tester
    git -C "${REPO}" config commit.gpgsign false
    git -C "${REPO}" commit -q --allow-empty -m init
    git -C "${REPO}" update-ref refs/remotes/origin/master HEAD
    git -C "${REPO}" branch skills/foo
    git -C "${REPO}" update-ref refs/remotes/origin/skills/foo-2 HEAD
}

@test "pick.zsh / lib.zsh: valid zsh syntax" {
    for f in "${PICK}" "${LIB}"; do
        run zsh -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "sc_unique_branch: skips local and remote branches that already exist" {
    make_repo
    lib "sc_unique_branch '${REPO}' bar"
    [ "$output" = "skills/bar" ]
    # skills/foo はローカル、skills/foo-2 は origin にだけある
    lib "sc_unique_branch '${REPO}' foo"
    [ "$output" = "skills/foo-3" ]
}

@test "sc_worktree_of: finds the worktree that has the branch checked out" {
    make_repo
    git -C "${REPO}" worktree add -q "${BATS_TEST_TMPDIR}/wt-foo" skills/foo
    lib "sc_worktree_of '${REPO}' skills/foo"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cd "${BATS_TEST_TMPDIR}/wt-foo" && pwd -P)" ] || [ "$output" = "${BATS_TEST_TMPDIR}/wt-foo" ]
    lib "sc_worktree_of '${REPO}' skills/none"
    [ "$status" -ne 0 ]
}

@test "sc_source_repo: resolves the repo top from SKILL_CREATE_REPO" {
    make_repo
    mkdir -p "${REPO}/home"
    run env SKILL_CREATE_REPO="${REPO}/home" zsh -c "source '${LIB}'; sc_source_repo"
    [ "$status" -eq 0 ]
    [ "$(cd "$output" && pwd -P)" = "$(cd "${REPO}" && pwd -P)" ]
}

@test "sc_render_prompt: fills every placeholder and folds the task onto one line" {
    lib "sc_render_prompt \$'shell の\nスキル' skills/x /wt/x /src master"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"作りたいもの: shell の スキル"* ]] || false
    [[ "$output" == *"skills/x"* ]] || false
    [[ "$output" == *"/src"* ]] || false
    [[ "$output" == *"skill-creator:skill-creator"* ]] || false
    [[ "$output" == *"gh pr merge"* ]] || false
    [[ "$output" == *"chezmoi apply ~/.claude/skills/"* ]] || false
    # 差し込み漏れ・注意書き（HTML コメント）の混入が無いこと
    [[ "$output" != *"{{"* ]] || false
    [[ "$output" != *"<!--"* ]] || false
}

@test "sc_render_prompt: falls back to a built-in prompt without the template" {
    SKILL_CREATE_PROMPT_FILE="${BATS_TEST_TMPDIR}/missing.md" lib "sc_render_prompt task skills/x /wt/x /src master"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skill-creator:skill-creator"* ]] || false
    [[ "$output" != *"{{"* ]] || false
}

@test "prompt.md: limits chezmoi apply to the new skill" {
    # 素の chezmoi apply はアプリが書き換えた settings.json などを潰す
    run grep -E 'chezmoi apply( --[a-z-]+)*$|chezmoi apply( --[a-z-]+)* で' "${REPO_ROOT}/${PLUGIN}/prompt.md"
    [ "$status" -ne 0 ]
}
