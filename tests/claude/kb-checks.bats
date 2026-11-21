#!/usr/bin/env bats

load ../test_helper

# kb の検査（checks/run）を Edit の後と、git commit・gh pr create の前に挟む hook を検証する。
# run はスタブにして、渡された引数と終了コードだけを見る。

setup() {
    HOOK="${REPO_ROOT}/home/dot_claude/hooks/executable_kb-checks.sh"
    export KB_CHECKS_RUN="${BATS_TEST_TMPDIR}/run"
    ARGS="${BATS_TEST_TMPDIR}/args"
    cat >"$KB_CHECKS_RUN" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$ARGS"
[ "\${STUB_RC:-0}" -eq 1 ] && echo "a.tsx:4:7: [kb/x] bad"
exit "\${STUB_RC:-0}"
STUB
    chmod +x "$KB_CHECKS_RUN"
    WT="${BATS_TEST_TMPDIR}/wt"
    git init -q "$WT"
    touch "$WT/a.tsx"
    unset SKIP_KB_CHECKS STUB_RC
}

edit_hook() {
    jq -n --arg f "${1:-$WT/a.tsx}" --arg t "${2:-Edit}" \
        '{hook_event_name: "PostToolUse", tool_name: $t, tool_input: {file_path: $f}}' | bash "$HOOK"
}

bash_hook() {
    jq -n --arg c "$1" --arg d "$WT" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | bash "$HOOK"
}

@test "kb-checks: after an edit, hands the violations back to Claude" {
    export STUB_RC=1
    run edit_hook
    [ "$status" -eq 0 ]
    [ "$(jq -r .decision <<<"$output")" = "block" ]
    [[ "$(jq -r .reason <<<"$output")" == *"a.tsx:4:7: [kb/x] bad"* ]] || false
    # 編集したファイルだけを、そのリポジトリで見る
    [ "$(cat "$ARGS")" = "$(printf '%s\n' --only "$WT/a.tsx" "$WT")" ]
}

@test "kb-checks: Write and MultiEdit are checked too" {
    export STUB_RC=1
    run edit_hook "$WT/a.tsx" Write
    [ "$(jq -r .decision <<<"$output")" = "block" ]
    run edit_hook "$WT/a.tsx" MultiEdit
    [ "$(jq -r .decision <<<"$output")" = "block" ]
}

@test "kb-checks: stays silent when clean, or for repositories without checks" {
    export STUB_RC=0
    run edit_hook
    [ -z "$output" ]
    # run は検査の無いリポジトリで 2 を返す
    export STUB_RC=2
    run edit_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "kb-checks: ignores files outside git repositories" {
    export STUB_RC=1
    touch "${BATS_TEST_TMPDIR}/loose.tsx"
    run edit_hook "${BATS_TEST_TMPDIR}/loose.tsx"
    [ -z "$output" ]
    [ ! -e "$ARGS" ]
}

@test "kb-checks: denies gh pr create while the branch has violations" {
    export STUB_RC=1
    run bash_hook "git push -u origin HEAD && gh pr create --draft"
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "deny" ]
    [[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")" == *"[kb/x] bad"* ]] || false
    # ブランチの変更全体を見る（--only を付けない）
    [ "$(cat "$ARGS")" = "$WT" ]
}

@test "kb-checks: other commands and mere mentions of gh pr create pass without running" {
    export STUB_RC=1
    run bash_hook "git status"
    [ -z "$output" ]
    run bash_hook "git log --grep 'gh pr create の前に検査する'"
    [ -z "$output" ]
    [ ! -e "$ARGS" ]
}

@test "kb-checks: SKIP_KB_CHECKS=1 or a missing kb turns it off" {
    export STUB_RC=1
    SKIP_KB_CHECKS=1 run edit_hook
    [ -z "$output" ]
    KB_CHECKS_RUN="${BATS_TEST_TMPDIR}/none" run edit_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "kb-checks: denies git commit while the branch has violations" {
    export STUB_RC=1
    run bash_hook "git add -A && git commit -m x"
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "deny" ]
    [[ "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$output")" == "commit する前に"*"[kb/x] bad"* ]] || false
    [ "$(cat "$ARGS")" = "$WT" ]
}

@test "kb-checks: git -C <path> commit checks that repository" {
    export STUB_RC=1
    OTHER="${BATS_TEST_TMPDIR}/other"
    git init -q "$OTHER"
    run bash_hook "git -C $OTHER commit -m x"
    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "deny" ]
    [ "$(cat "$ARGS")" = "$OTHER" ]
    # 引用符付きと、hook に渡された cwd からの相対パス
    mkdir "$WT/sub"; git init -q "$WT/sub"
    run bash_hook "git -C \"$OTHER\" commit -m x"
    [ "$(cat "$ARGS")" = "$OTHER" ]
    run bash_hook "git -C sub commit -m x"
    [ "$(cat "$ARGS")" = "$WT/sub" ]
    # メッセージの中の -C は、見るリポジトリを変えない
    run bash_hook "git commit -m 'revert git -C $OTHER commit'"
    [ "$(cat "$ARGS")" = "$WT" ]
}

@test "kb-checks: git global options before commit do not hide it" {
    export STUB_RC=1
    for c in "git -c user.name=x commit -m x" "git --no-pager commit -m x" "GIT_EDITOR=true git commit --amend"; do
        rm -f "$ARGS"
        run bash_hook "$c"
        [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$output")" = "deny" ]
        [ "$(cat "$ARGS")" = "$WT" ]
    done
}

@test "kb-checks: commit only counts when git commit is invoked" {
    export STUB_RC=1
    run bash_hook 'git log --grep "git commit"'
    [ -z "$output" ]
    run bash_hook "git commit-graph write"
    [ -z "$output" ]
    run bash_hook "git show commit"
    [ -z "$output" ]
    [ ! -e "$ARGS" ]
}
