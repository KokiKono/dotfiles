#!/usr/bin/env bats

load ../test_helper

# report-my-channel スキルの local-routine.sh を検証する。
# 置き場・launchctl・claude をすべて tmpdir とスタブに向けるので、実機の launchd には登録しない。

SCRIPT="home/dot_claude/skills/report-my-channel/scripts/executable_local-routine.sh"

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    LR="${REPO_ROOT}/${SCRIPT}"
    export REPORT_MY_CHANNEL_HOME="${BATS_TEST_TMPDIR}/home"
    export REPORT_MY_CHANNEL_AGENTS_DIR="${BATS_TEST_TMPDIR}/agents"
    export REPORT_MY_CHANNEL_LOG_DIR="${BATS_TEST_TMPDIR}/logs"
    mkdir -p "${REPORT_MY_CHANNEL_HOME}/routines" "${BATS_TEST_TMPDIR}/bin"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    cat >"${BATS_TEST_TMPDIR}/bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "launchctl \$*" >>"${CALLS}"
EOF
    cat >"${BATS_TEST_TMPDIR}/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${CALLS}.claude"
echo "\${CLAUDE_STUB_OUT:-\$(cat "${BATS_TEST_TMPDIR}/ok.json")}"
EOF
    printf '%s\n' '{"is_error":false,"result":"done\nREPORT: OK"}' >"${BATS_TEST_TMPDIR}/ok.json"
    cat >"${BATS_TEST_TMPDIR}/bin/osascript" <<EOF
#!/usr/bin/env bash
echo "osascript \$*" >>"${CALLS}"
EOF
    chmod +x "${BATS_TEST_TMPDIR}/bin/"*
    export LAUNCHCTL="${BATS_TEST_TMPDIR}/bin/launchctl"
    export REPORT_MY_CHANNEL_CLAUDE="${BATS_TEST_TMPDIR}/bin/claude"
    export OSASCRIPT="${BATS_TEST_TMPDIR}/bin/osascript"
    P="${REPORT_MY_CHANNEL_AGENTS_DIR}/com.kokikono.report-my-channel.daily.plist"
    cat >"${REPORT_MY_CHANNEL_HOME}/routines/daily.md" <<'EOF'
---
allowed_tools: "Bash(ls *),mcp__x__y"
---
自分の PR の状況を報告する
頻度: 平日 18 時
EOF
}

@test "install: writes a weekday plist and bootstraps it" {
    run bash "${LR}" install daily 18:05 1,5
    [ "$status" -eq 0 ]
    [ -f "${P}" ]
    plutil -lint "${P}" >/dev/null
    grep -q '<key>Weekday</key><integer>1</integer><key>Hour</key><integer>18</integer><key>Minute</key><integer>5</integer>' "${P}"
    grep -q '<key>Weekday</key><integer>5</integer>' "${P}"
    grep -q "<string>${LR}</string>" "${P}"
    grep -q '<string>run</string>' "${P}"
    grep -q 'launchctl bootstrap' "${CALLS}"
}

@test "install: multiple times expand to every weekday and time pair" {
    run bash "${LR}" install daily 09:00,13:00,17:00 1,2,3,4,5
    [ "$status" -eq 0 ]
    plutil -lint "${P}" >/dev/null
    run grep -c '<key>Weekday</key>' "${P}"
    [ "$output" = "15" ]
    grep -q '<key>Weekday</key><integer>5</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>0</integer>' "${P}"
}

@test "install: without weekdays runs every day" {
    run bash "${LR}" install daily 09:00
    [ "$status" -eq 0 ]
    plutil -lint "${P}" >/dev/null
    run grep -c 'Weekday' "${P}"
    [ "$output" = "0" ]
}

@test "install: rejects bad time, weekday, slug and missing definition" {
    run bash "${LR}" install daily 25:00
    [ "$status" -ne 0 ]
    run bash "${LR}" install daily 09:00 7
    [ "$status" -ne 0 ]
    run bash "${LR}" install daily 09:00,9:00
    [ "$status" -ne 0 ]
    run bash "${LR}" install ../x 09:00
    [ "$status" -ne 0 ]
    run bash "${LR}" install nothing 09:00
    [ "$status" -ne 0 ]
    [ ! -e "${CALLS}" ]
}

@test "list and uninstall: round trip" {
    bash "${LR}" install daily 09:00
    run bash "${LR}" list
    [[ "$output" == daily* ]] || false
    run bash "${LR}" uninstall daily
    [ "$status" -eq 0 ]
    [ ! -e "${P}" ]
    run bash "${LR}" list
    [ -z "$output" ]
}

@test "run: passes the body without frontmatter and merges extra tools" {
    run bash "${LR}" run daily
    [ "$status" -eq 0 ]
    grep -q '^/report-my-channel run 自分の PR の状況を報告する$' "${CALLS}.claude"
    run grep -c 'allowed_tools' "${CALLS}.claude"
    [ "$output" = "0" ]
    grep -q 'mcp__claude_ai_Slack__slack_send_message' "${CALLS}.claude"
    grep -q 'Bash(ls \*),mcp__x__y' "${CALLS}.claude"
    # YAML の引用符はツール名に含めない
    run grep -q '"' "${CALLS}.claude"
    [ "$status" -ne 0 ]
}

@test "run: notifies and fails when claude reports an error" {
    CLAUDE_STUB_OUT='{"is_error":true,"result":"denied"}' run bash "${LR}" run daily
    [ "$status" -ne 0 ]
    grep -q 'osascript' "${CALLS}"
}

@test "run: fails when the skill does not report REPORT: OK" {
    CLAUDE_STUB_OUT='{"is_error":false,"result":"REPORT: NG slack denied"}' run bash "${LR}" run daily
    [ "$status" -ne 0 ]
    grep -q 'osascript' "${CALLS}"
}

@test "run: logs denied tools" {
    CLAUDE_STUB_OUT='{"is_error":false,"result":"REPORT: OK","permission_denials":[{"tool_name":"Bash"}]}' run bash "${LR}" run daily
    [ "$status" -eq 0 ]
    [[ "$output" == *"拒否されたツール: Bash"* ]] || false
}

@test "uninstall: unloads the job even when the plist is already gone" {
    run bash "${LR}" uninstall daily
    [ "$status" -eq 0 ]
    grep -q 'launchctl bootout' "${CALLS}"
}
