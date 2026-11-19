#!/usr/bin/env bats

load ../test_helper

# このリポジトリで gh pr merge の後に apply-merged を実行させる、プロジェクトの hook を検証する。

setup() {
    HOOK="${REPO_ROOT}/.claude/hooks/after-merge.sh"
}

run_hook() {
    jq -n --arg c "$1" '{tool_input: {command: $c}}' | bash "$HOOK"
}

context() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }

@test "after-merge: asks for apply-merged with the merged PR number" {
    run run_hook "gh pr merge 73 --squash"
    [[ "$(context)" == *"apply-merged を引数 73 で"* ]] || false
    run run_hook "gh pr merge https://github.com/o/r/pull/74 --squash"
    [[ "$(context)" == *"引数 74 で"* ]] || false
}

@test "after-merge: without a number, leaves finding the PR to Claude" {
    run run_hook "gh pr merge --squash"
    [[ "$(context)" == *"gh pr view で確かめて"* ]] || false
}

@test "after-merge: does not take a number from flag values as the PR" {
    run run_hook "gh pr merge --squash --subject \"Fix 12\" -b 'see 13' --body-file 14"
    [[ "$(context)" == *"gh pr view で確かめて"* ]] || false
    run run_hook "gh pr merge --squash -t 'Fix 12' 75"
    [[ "$(context)" == *"引数 75 で"* ]] || false
}

@test "after-merge: skips auto-merge, other repositories and mere mentions" {
    run run_hook "gh pr merge 73 --auto --squash"
    [ -z "$output" ]
    run run_hook "gh pr merge 73 --repo o/other"
    [ -z "$output" ]
    run run_hook "git commit -m 'gh pr merge の後に apply する'"
    [ -z "$output" ]
    run run_hook "git status"
    [ -z "$output" ]
}

@test "after-merge: the project settings register the hook" {
    run jq -r '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[].command' "${REPO_ROOT}/.claude/settings.json"
    [[ "$output" == *".claude/hooks/after-merge.sh"* ]] || false
}
