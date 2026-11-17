#!/usr/bin/env bats

load ../test_helper

# 英語の返答で止めて日本語での書き直しを求める Stop hook を検証する。

setup() {
    HOOK="${REPO_ROOT}/home/dot_claude/hooks/executable_japanese-reply.py"
    TRANSCRIPT="${BATS_TEST_TMPDIR}/t.jsonl"
    : >"$TRANSCRIPT"
    unset SKIP_JAPANESE_REPLY
    export CLAUDE_CODE_ENTRYPOINT=cli
}

user() {
    jq -cn --arg t "$1" '{type: "user", message: {content: $t}}' >>"$TRANSCRIPT"
}

assistant() {
    jq -cn --arg t "$1" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}' >>"$TRANSCRIPT"
}

tool_result() {
    jq -cn '{type: "user", message: {content: [{type: "tool_result", content: "ok"}]}}' >>"$TRANSCRIPT"
}

assert_blocked() {
    [ "$(jq -r .decision <<<"$output")" = "block" ]
}

assert_passed() {
    [ -z "$output" ]
}

run_hook() {
    jq -n --arg p "$TRANSCRIPT" --argjson a "${1:-false}" \
        '{transcript_path: $p, stop_hook_active: $a}' | python3 "$HOOK"
}

@test "japanese-reply: english reply is blocked" {
    user "直して"
    assistant "Build 79 still fails resize, so the iOS flag wasn't the cause."
    run run_hook
    [ "$status" -eq 0 ]
    assert_blocked
    jq -r .reason <<<"$output" | grep -qF "日本語"
}

@test "japanese-reply: japanese reply with identifiers passes" {
    user "直して"
    assistant "PR #123 を作りました。\`table_seats\` が空の予約を Table Chart で除外しています。"
    run run_hook
    [ "$status" -eq 0 ]
    assert_passed
}

@test "japanese-reply: english only inside code, urls or quotes passes" {
    user "ログを見て"
    assistant $'```\nYou attempted to set the key on an object that is meant to be immutable\n```\n> Error: cannot read property of undefined\nhttps://example.com/some/long/path'
    run run_hook
    assert_passed
}

@test "japanese-reply: english link titles, table data and japanese quotes are judged right" {
    user "調べて"
    assistant $'参考資料です。\n- [How to Transfer a Domain From Any Registrar](https://example.com)\n| ロケール | 文言 |\n| en | There has been a reservation request from a customer |'
    run run_hook
    assert_passed

    # 英文の中に「」で日本語を引用していても英語とみなす
    assistant "The result for No.12 「アプリ内の WebView が表示される」 is still pending."
    run run_hook
    assert_blocked
}

@test "japanese-reply: english lines inside a japanese reply pass" {
    user "調べて"
    assistant $'エラーの原因を調べました。ログには次の行が出ています。\nCountry not found for the given code in this row\n````markdown\n```\nYou attempted to set the key on an immutable object\n```\n````\nこの行は前の PR で直した箇所と同じです。'
    run run_hook
    assert_passed
}

@test "japanese-reply: english opener before a japanese body is blocked" {
    user "直して"
    assistant $'Sorry, I wrote the proposal in English again.\n\n命名案を日本語で書き直します。'
    run run_hook
    assert_blocked
}

@test "japanese-reply: only the final reply is judged" {
    # 途中の英語で止めると、日本語の回答全体を出し直させてしまう
    user "調べて"
    assistant "I'm checking the reservation data in the DB."
    tool_result
    assistant "予約データを確認しました。"
    run run_hook
    assert_passed

    assistant "Now record results in Notion."
    tool_result
    assistant "All four results are recorded in the QA checklist."
    run run_hook
    assert_blocked
}

@test "japanese-reply: english in an earlier turn is ignored" {
    user "a"
    assistant "Here's where QA stands right now."
    user "日本語で"
    assistant "QA の状況をまとめます。"
    run run_hook
    assert_passed
}

@test "japanese-reply: last_assistant_message is checked without a transcript" {
    run python3 "$HOOK" <<<'{"last_assistant_message": "The AI review found nothing."}'
    assert_blocked
}

@test "japanese-reply: second stop after a rewrite is not blocked again" {
    user "直して"
    assistant "The build is in the EAS queue now."
    run run_hook true
    assert_passed
}

@test "japanese-reply: headless sdk runs and SKIP_JAPANESE_REPLY=1 are skipped" {
    user "直して"
    assistant "The build is in the EAS queue now."
    CLAUDE_CODE_ENTRYPOINT=sdk-cli run run_hook
    assert_passed
    SKIP_JAPANESE_REPLY=1 run run_hook
    assert_passed
}

@test "japanese-reply: a prompt with a pasted image ends the previous turn" {
    user "a"
    assistant "Here's where QA stands right now."
    jq -cn '{type: "user", message: {content: [{type: "text", text: "直して"}, {type: "image"}]}}' >>"$TRANSCRIPT"
    assistant "直しました。"
    run run_hook
    assert_passed
}

@test "japanese-reply: injected notifications are not taken as the prompt" {
    user "この文言を英訳して"
    user "<task-notification>translate it into English</task-notification>"
    jq -cn '{type: "user", isMeta: true, message: {content: "in English"}}' >>"$TRANSCRIPT"
    assistant "There has been a reservation request from a customer."
    run run_hook
    assert_passed

    user "調べて"
    user "<task-notification>translate it into English</task-notification>"
    assistant "The DB check is done and nothing was wrong."
    run run_hook
    assert_blocked
}

@test "japanese-reply: english asked by the user passes" {
    user "この文言を英訳して"
    assistant "There has been a reservation request from a customer."
    run run_hook
    assert_passed

    user "PR 本文は英語で書いて"
    assistant "This PR adds a stop hook that rewrites English replies."
    run run_hook
    assert_passed

    # 英語の返答への苦情や識別子は英語の依頼ではない
    for prompt in "英語で返さないで" "また英語になってる" "translateText を直して"; do
        user "$prompt"
        assistant "Got it, I will reply in Japanese from now on."
        run run_hook
        assert_blocked
    done
}

@test "japanese-reply: english titles at the top of a japanese reply pass" {
    user "PR 作って"
    assistant $'## Fix crash when table seats are empty\n\nPR を作りました。'
    run run_hook
    assert_passed
}

@test "japanese-reply: a compact summary ends the turn but is not a prompt" {
    user "この文言を英訳して"
    jq -cn '{type: "user", isCompactSummary: true, message: {content: "summary: translate it into English"}}' >>"$TRANSCRIPT"
    assistant "There has been a reservation request from a customer."
    run run_hook
    assert_blocked
}

@test "japanese-reply: tilde fences are excluded and bad input passes" {
    user "ログを見て"
    assistant $'~~~\nYou attempted to set the key on an immutable object\n~~~\nログを確認しました。'
    run run_hook
    assert_passed

    run python3 "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    assert_passed

    run python3 "$HOOK" <<<'[]'
    [ "$status" -eq 0 ]
    assert_passed
}

@test "japanese-reply: replies before the previous stop are not judged again" {
    user "この文言を英訳して"
    assistant "Checking the wording now before translating."
    jq -cn '{type: "system", subtype: "stop_hook_summary"}' >>"$TRANSCRIPT"
    user "<task-notification>done</task-notification>"
    assistant "There has been a reservation request from a customer."
    run run_hook
    # 前回の Stop より前は見ないが、英語の依頼かどうかは元の入力で判断する
    assert_passed

    : >"$TRANSCRIPT"
    user "直して"
    assistant "Next, I'll add tests for these cases."
    jq -cn '{type: "system", subtype: "stop_hook_summary"}' >>"$TRANSCRIPT"
    jq -cn '{type: "user", isMeta: true, message: {content: "Stop hook feedback:\n書き直して"}}' >>"$TRANSCRIPT"
    assistant "書き直しました。"
    run run_hook
    assert_passed
}
