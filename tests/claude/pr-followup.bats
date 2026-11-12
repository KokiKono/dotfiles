#!/usr/bin/env bats

load ../test_helper

# gh pr create の後に /pr-followup を促す hook と、レビュー状態を出すスクリプトを検証する。

setup() {
    HOOK="${REPO_ROOT}/home/dot_claude/hooks/executable_pr-followup.sh"
    STATUS="${REPO_ROOT}/home/dot_claude/skills/pr-followup/scripts/executable_pr-review-status.py"
    unset SKIP_PR_FOLLOWUP
    export PR_FOLLOWUP_CONFIG="${BATS_TEST_TMPDIR}/none.json"
}

run_hook() {
    jq -n --arg c "$1" --arg o "${2:-}" \
        '{tool_input: {command: $c}, tool_response: {stdout: $o, stderr: ""}}' | bash "$HOOK"
}

URL=https://github.com/o/r/pull/12

@test "pr-followup hook: other commands pass silently" {
    run run_hook "git status" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pr-followup hook: created PR asks to run the skill with its URL" {
    run run_hook "gh pr create --draft --title x" "$URL"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "PostToolUse" ]
    jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF "pr-followup"
    jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF "$URL"
}

@test "pr-followup hook: env assignments before gh are allowed" {
    run run_hook "cd x && GH_TOKEN=t gh pr create --title x" "Creating...
$URL"
    jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF "$URL"
}

@test "pr-followup hook: failed create without URL does nothing" {
    run run_hook "gh pr create --title x" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pr-followup hook: string inside a commit message is ignored" {
    run run_hook "git commit -m 'run gh pr create later'" "$URL"
    [ -z "$output" ]
}

@test "pr-followup hook: SKIP_PR_FOLLOWUP=1 skips" {
    SKIP_PR_FOLLOWUP=1 run run_hook "gh pr create --title x" "$URL"
    [ -z "$output" ]
}

# gh をスタブして、graphql には graphql.json を、run list には空を返す
stub_gh() {
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "api graphql") cat "${BATS_TEST_TMPDIR}/graphql.json" ;;
  "run list") echo '[]' ;;
esac
EOF
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
}

pr_json() {
    # $1: reviewThreads の nodes, $2: comments の nodes, $3: workflow（null なら pr-review.yml が無い）
    # 既定値を heredoc の中の ${3:-...} で書かない。macOS の bash 3.2 では } の扱いが違い、JSON が壊れる
    local workflow=${3:-'{"id":"w"}'}
    cat <<EOF
{"data":{"repository":{"workflow":$workflow,"pullRequest":{
  "headRefOid":"abc","isDraft":true,"labels":{"nodes":[]},
  "reviews":{"nodes":[{"author":{"login":"claude"},"body":"found 0 new potential bugs","state":"COMMENTED","commit":{"oid":"abc"},"submittedAt":"","url":"u"}]},
  "comments":{"nodes":$2},
  "reviewThreads":{"nodes":$1}
}}}}
EOF
}

bot() { printf '{"login":"%s","__typename":"Bot"}' "$1"; }
human() { printf '{"login":"%s","__typename":"User"}' "$1"; }

@test "pr-review-status: unresolved i18n bot thread keeps the PR from being clean" {
    pr_json "[{\"id\":\"T1\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"nodes\":[
        {\"databaseId\":1,\"body\":\"Missing i18n key\",\"path\":\"a.tsx\",\"url\":\"u1\",\"author\":$(bot i18n-bot)}]}}]" "[]" >"${BATS_TEST_TMPDIR}/graphql.json"; stub_gh
    run python3 "$STATUS" o/r 12
    [ "$status" -eq 0 ]
    [ "$(jq -r .state <<<"$output")" = "has_findings" ]
    [ "$(jq -r '.i18n[0].kind' <<<"$output")" = "thread" ]
    [ "$(jq -r '.draft' <<<"$output")" = "true" ]
}

@test "pr-review-status: humans and unrelated bot comments are not i18n warnings" {
    pr_json "[{\"id\":\"T1\",\"isResolved\":false,\"isOutdated\":false,\"comments\":{\"nodes\":[
        {\"databaseId\":1,\"body\":\"i18n を見直して\",\"path\":\"a.tsx\",\"url\":\"u1\",\"author\":$(human alice)}]}}]" \
        "[{\"databaseId\":2,\"body\":\"Bundle Size\",\"url\":\"u2\",\"isMinimized\":false,\"author\":$(bot relativeci)}]" >"${BATS_TEST_TMPDIR}/graphql.json"; stub_gh
    run python3 "$STATUS" o/r 12
    [ "$(jq -r .state <<<"$output")" = "clean" ]
    [ "$(jq '.i18n | length' <<<"$output")" -eq 0 ]
}

@test "pr-review-status: plain i18n comments are listed but do not block clean" {
    # 普通のコメントは解決済みの印を持たないので、state に数えるとループが終わらない
    pr_json "[]" "[{\"databaseId\":2,\"body\":\"translation issues found\",\"url\":\"u2\",\"isMinimized\":false,\"author\":$(bot i18n-bot)}]" >"${BATS_TEST_TMPDIR}/graphql.json"; stub_gh
    run python3 "$STATUS" o/r 12
    [ "$(jq -r .state <<<"$output")" = "clean" ]
    [ "$(jq -r '.i18n[0].kind' <<<"$output")" = "comment" ]
}

@test "pr-review-status: i18n_bots in the config narrows the authors" {
    echo '{"i18n_bots":["i18n-bot"]}' >"${BATS_TEST_TMPDIR}/c.json"
    export PR_FOLLOWUP_CONFIG="${BATS_TEST_TMPDIR}/c.json"
    pr_json "[]" "[{\"databaseId\":2,\"body\":\"i18n\",\"url\":\"u2\",\"isMinimized\":false,\"author\":$(bot other-bot)}]" >"${BATS_TEST_TMPDIR}/graphql.json"; stub_gh
    run python3 "$STATUS" o/r 12
    [ "$(jq '.i18n | length' <<<"$output")" -eq 0 ]
}

@test "pr-review-status: repos without the claude-review workflow are no_review" {
    # gh run list は存在しない workflow で失敗するので、呼ぶ前に抜けること
    pr_json "[]" "[]" null >"${BATS_TEST_TMPDIR}/graphql.json"; stub_gh
    printf '#!/bin/bash\n[ "$1 $2" = "api graphql" ] && exec cat "%s/graphql.json"\nexit 1\n' "${BATS_TEST_TMPDIR}" >"${BATS_TEST_TMPDIR}/bin/gh"
    run python3 "$STATUS" o/r 12
    [ "$status" -eq 0 ]
    [ "$(jq -r .state <<<"$output")" = "no_review" ]
}
