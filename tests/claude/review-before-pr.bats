#!/usr/bin/env bats

load ../test_helper

# gh pr create の前に /simplify → /code-review を求める hook を検証する。
# トランスクリプトは Claude Code の JSONL の形を最小限で写したもの。

setup() {
    HOOK="${REPO_ROOT}/home/dot_claude/hooks/executable_review-before-pr.sh"
    T="${BATS_TEST_TMPDIR}/t.jsonl"
    : >"$T"
    unset SKIP_PR_REVIEW
}

skill() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$1" >>"$T"; }
edit() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}\n' >>"$T"; }
slash() { printf '{"type":"user","message":{"content":"<command-name>/%s</command-name>"}}\n' "$1" >>"$T"; }
result() { printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}\n' >>"$T"; }
mention() { printf '{"type":"attachment","message":{"content":"- simplify: ... - code-review: ..."}}\n' >>"$T"; }

run_hook() {
    jq -n --arg c "${1:-gh pr create --title x}" --arg t "$T" --arg d "${2:-}" \
        '{tool_input: {command: $c}, transcript_path: $t, cwd: $d}' | bash "$HOOK"
}

denied() { [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]; }

@test "review-before-pr: other commands pass" {
    run run_hook "git status"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "review-before-pr: skill names merely mentioned do not count" {
    # 以前は文字列 grep だったので、スキル一覧に名前が出ているだけで通っていた
    mention
    run run_hook
    denied
}

@test "review-before-pr: simplify then code-review after the last edit passes" {
    edit; skill simplify; edit; skill code-review
    run run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "review-before-pr: tool results after the reviews do not erase them" {
    # user レコードはほとんどがコマンド名を持たない tool_result。それで記録が消えてはいけない
    edit; result; skill simplify; result; skill code-review; result
    run run_hook
    [ -z "$output" ]
}

@test "review-before-pr: slash commands typed by the user count too" {
    edit; slash simplify; slash code-review
    run run_hook
    [ -z "$output" ]
}

@test "review-before-pr: code-review before simplify is not enough" {
    edit; skill code-review; skill simplify
    run run_hook
    denied
    [[ "$output" == *"/simplify の後の /code-review"* ]] || false
}

@test "review-before-pr: editing after code-review requires another code-review" {
    skill simplify; skill code-review; edit
    run run_hook
    denied
    [[ "$output" == *"もう一度"* ]] || false
}

@test "review-before-pr: the command string only counts when gh pr create is invoked" {
    # コミットメッセージや grep の引数に含まれるだけなら止めない
    run run_hook 'git commit -m "gh pr create の前に止める"'
    [ -z "$output" ]
    run run_hook 'git push && gh pr create --fill'
    denied
    run run_hook $'git push\n  gh pr create --fill'
    denied
    run run_hook '  gh pr create'
    denied
}

@test "review-before-pr: docs/ and README only diffs pass, other markdown does not" {
    # このリポジトリでは SKILL.md などの .md が本体なので、拡張子では外さない
    R="${BATS_TEST_TMPDIR}/repo"
    git init -q -b main "$R"
    git -C "$R" config user.name t
    git -C "$R" config user.email t@example.com
    git -C "$R" config commit.gpgsign false
    git -C "$R" commit -q --allow-empty -m init
    # origin/HEAD の無い clone でも main を既定ブランチとして見つける
    git -C "$R" update-ref refs/remotes/origin/main HEAD
    mkdir -p "$R/docs"; echo doc >"$R/docs/a.md"; echo r >"$R/README.md"
    git -C "$R" add -A; git -C "$R" commit -q -m doc
    run run_hook "gh pr create" "$R"
    [ -z "$output" ]
    echo skill >"$R/SKILL.md"; git -C "$R" add -A; git -C "$R" commit -q -m skill
    run run_hook "gh pr create" "$R"
    denied
}

@test "review-before-pr: SKIP_PR_REVIEW only works from the environment" {
    run run_hook "SKIP_PR_REVIEW=1 gh pr create"
    denied
    SKIP_PR_REVIEW=1 run run_hook
    [ -z "$output" ]
}
