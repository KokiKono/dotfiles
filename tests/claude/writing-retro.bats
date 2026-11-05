#!/usr/bin/env bats

load ../test_helper

# writing-retro スキルの retro.sh を検証する。
# RETRO_HOME と CLAUDE_PROJECTS_DIR を tmpdir に向けるので ~/.claude は一切触らない。

SCRIPT="home/dot_claude/skills/writing-retro/scripts/executable_retro.sh"

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    RETRO="${REPO_ROOT}/${SCRIPT}"
    export RETRO_HOME="${BATS_TEST_TMPDIR}/retro"
    export CLAUDE_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
    mkdir -p "${CLAUDE_PROJECTS_DIR}/proj/s1/subagents"
    T="${CLAUDE_PROJECTS_DIR}/proj/s1.jsonl"
    # 1 セッション分の記録。候補になるのは u-keep と u-late の 2 件だけ
    cat >"${T}" <<'EOF'
{"type":"user","uuid":"u-old","sessionId":"s1","cwd":"/w/repo","timestamp":"2026-01-01T00:00:00Z","message":{"content":"古い発言"}}
{"type":"user","uuid":"u-plain","sessionId":"s1","cwd":"/w/repo","timestamp":"2026-01-31T00:00:00Z","message":{"content":"続けて"}}
{"type":"assistant","uuid":"a1","sessionId":"s1","timestamp":"2026-02-01T00:00:00Z","message":{"content":[{"type":"text","text":"論点09を残しました"}]}}
{"type":"assistant","uuid":"a2","sessionId":"s1","timestamp":"2026-02-01T00:00:01Z","message":{"content":[{"type":"tool_use","name":"mcp__claude_ai_Notion__notion-update-page","input":{}}]}}
{"type":"user","uuid":"u-tool","sessionId":"s1","timestamp":"2026-02-01T00:00:02Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"user","uuid":"u-meta","isMeta":true,"sessionId":"s1","timestamp":"2026-02-01T00:00:03Z","message":{"content":"Base directory for this skill"}}
{"type":"user","uuid":"u-cmd","sessionId":"s1","timestamp":"2026-02-01T00:00:04Z","message":{"content":"<command-name>/clear</command-name>"}}
{"type":"user","uuid":"u-side","isSidechain":true,"sessionId":"s1","timestamp":"2026-02-01T00:00:05Z","message":{"content":"subagent への指示"}}
{"type":"user","uuid":"u-sdk","entrypoint":"sdk-cli","sessionId":"s1","timestamp":"2026-02-01T00:00:06Z","message":{"content":"claude -p の入力。分かりにくい"}}
{"type":"user","uuid":"u-compact","isCompactSummary":true,"sessionId":"s1","timestamp":"2026-02-01T00:00:06Z","message":{"content":"This session is being continued. 分かりにくい"}}
{"type":"user","uuid":"u-keep","sessionId":"s1","cwd":"/w/repo","timestamp":"2026-02-01T00:00:07Z","message":{"content":"09という書き方が分かりにくい。\n省略しないで"}}
{"type":"assistant","uuid":"a3","sessionId":"s1","timestamp":"2026-02-01T00:00:08Z","message":{"content":[{"type":"text","text":"直しました"}]}}
{"type":"user","uuid":"u-late","sessionId":"s1","cwd":"/w/repo","timestamp":"2026-02-02T00:00:00Z","message":{"content":[{"type":"text","text":"箇条書きにして"}]}}
EOF
    # 語に当たっても長すぎる発言（貼り付けた資料）は候補にしない
    jq -nc '{type:"user",uuid:"u-paste",sessionId:"s1",timestamp:"2026-02-02T00:00:01Z",
             message:{content:("貼り付けた資料。分かりにくい" + ("あ" * 700))}}' >>"${T}"
    # subagent の記録は丸ごと読まない
    echo '{"type":"user","uuid":"u-sub","sessionId":"s1","timestamp":"2026-02-01T00:00:09Z","message":{"content":"sub"}}' \
        >"${CLAUDE_PROJECTS_DIR}/proj/s1/subagents/agent-x.jsonl"
}

@test "retro: valid bash syntax" {
    run bash -n "${RETRO}"
    [ "$status" -eq 0 ]
}

@test "retro: sourcing defines commands without running them" {
    run bash -c "source '${RETRO}'; declare -f cmd_extract cmd_list cmd_context cmd_commit cmd_log cmd_stats cmd_budget >/dev/null && echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || false
    [ ! -e "${RETRO_HOME}" ]
}

@test "retro: extract keeps only human messages that hit the lexicon" {
    run bash "${RETRO}" extract --since 2026-01-15T00:00:00Z
    [ "$status" -eq 0 ]
    # 人の発言は u-plain / u-keep / u-late / u-paste の 4 件、候補はそのうち 2 件
    run jq -e '.scanned == 4 and .messages == 2 and .since == "2026-01-15T00:00:00Z"' "${RETRO_HOME}/pending.meta.json"
    [ "$status" -eq 0 ]
    run jq -r '.uuid' "${RETRO_HOME}/pending.jsonl"
    [ "${lines[0]}" = "u-keep" ]
    [ "${lines[1]}" = "u-late" ]
}

@test "retro: extract --all keeps every human message" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z --all >/dev/null
    run jq -r '.uuid' "${RETRO_HOME}/pending.jsonl"
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" = "u-plain" ]
}

@test "retro: extract tags the medium the assistant wrote just before" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run jq -r '"\(.uuid) \(.medium)"' "${RETRO_HOME}/pending.jsonl"
    # u-keep の直前で Notion を更新している。媒体はターンごとに戻すので u-late は chat
    [ "${lines[0]}" = "u-keep notion" ]
    [ "${lines[1]}" = "u-late chat" ]
}

@test "retro: extract attaches the preceding assistant text" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run jq -r 'select(.uuid == "u-keep") | .prev' "${RETRO_HOME}/pending.jsonl"
    [ "$output" = "論点09を残しました" ]
    run jq -r 'select(.uuid == "u-late") | .prev' "${RETRO_HOME}/pending.jsonl"
    [ "$output" = "直しました" ]
}

@test "retro: extract truncates long messages and marks them" {
    export RETRO_USER_CHARS=5
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run jq -r 'select(.uuid == "u-keep") | "\(.user)|\(.user_truncated)"' "${RETRO_HOME}/pending.jsonl"
    [ "$output" = "09という|true" ]
}

@test "retro: list prints each message with the tail of the preceding reply" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run bash "${RETRO}" list
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [[ "${lines[0]}" == u-keep*"notion"*"repo"*"分かりにくい。 省略しないで" ]] || false
    [[ "${lines[1]}" == *"← 論点09を残しました" ]] || false
    run bash "${RETRO}" list --short
    [ "${#lines[@]}" -eq 2 ]
}

@test "retro: context returns the full preceding assistant text by id prefix" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run bash "${RETRO}" context u-ke
    [ "$status" -eq 0 ]
    [[ "$output" == *"論点09を残しました"*"--- user ---"*"省略しないで"* ]] || false
    run bash "${RETRO}" context nope
    [ "$status" -ne 0 ]
}

@test "retro: commit advances since and the next extract starts there" {
    bash "${RETRO}" extract --since 2026-01-15T00:00:00Z >/dev/null
    run bash "${RETRO}" commit
    [ "$status" -eq 0 ]
    [ ! -e "${RETRO_HOME}/pending.jsonl" ]
    # cursor は extract した時点（現在）に進むので、fixture の発言はもう出ない
    run jq -e '.since > "2026-02-02"' "${RETRO_HOME}/state.json"
    [ "$status" -eq 0 ]
    run bash "${RETRO}" extract
    [ "$status" -eq 0 ]
    run jq -e '.messages == 0' "${RETRO_HOME}/pending.meta.json"
    [ "$status" -eq 0 ]
}

@test "retro: commit without extract fails and leaves state alone" {
    run bash "${RETRO}" commit
    [ "$status" -ne 0 ]
    [ ! -e "${RETRO_HOME}/state.json" ]
}

@test "retro: log appends dated entries and stats counts repeats per rule" {
    E="${BATS_TEST_TMPDIR}/entries.json"
    echo '[{"quote":"省略しないで","action":"added","rule":"略記を使わない"},
           {"quote":"また略してる","action":"strengthened","rule":"略記を使わない"},
           {"quote":"この節も足して","action":"skipped","reason":"中身の注文"}]' >"${E}"
    run bash "${RETRO}" log "${E}"
    [ "$status" -eq 0 ]
    run jq -s -e 'length == 3 and all(.[]; .date != null)' "${RETRO_HOME}/log.jsonl"
    [ "$status" -eq 0 ]
    run bash "${RETRO}" stats
    [ "$status" -eq 0 ]
    run jq -e 'length == 1 and .[0].rule == "略記を使わない" and .[0].count == 2' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "retro: log rejects entries without quote or action" {
    E="${BATS_TEST_TMPDIR}/bad.json"
    echo '[{"rule":"x"}]' >"${E}"
    run bash "${RETRO}" log "${E}"
    [ "$status" -ne 0 ]
    [ ! -e "${RETRO_HOME}/log.jsonl" ]
}

@test "retro: budget counts rules and flags when over the limit" {
    export RETRO_RULES="${BATS_TEST_TMPDIR}/writing.md"
    printf '# 見出し\n\n- ルール1\n- ルール2\n  例の行\n- ルール3\n' >"${RETRO_RULES}"
    run bash "${RETRO}" budget
    [ "$status" -eq 0 ]
    run jq -e '.rules == 3 and .over == false' <<<"$output"
    [ "$status" -eq 0 ]
    export RETRO_RULES_LIMIT=2
    run bash "${RETRO}" budget
    run jq -e '.over == true' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "retro: the shipped rules file stays within the budget" {
    export RETRO_RULES="${REPO_ROOT}/home/dot_claude/rules/writing.md"
    run bash "${RETRO}" budget
    [ "$status" -eq 0 ]
    run jq -e '.over == false' <<<"$output"
    [ "$status" -eq 0 ]
}
