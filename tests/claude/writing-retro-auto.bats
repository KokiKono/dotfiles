#!/usr/bin/env bats

load ../test_helper

# writing-retro の自動実行（auto.sh）を検証する。claude は PATH 上のスタブに差し替え、
# 呼ばれた引数を記録する。通知は RETRO_NO_NOTIFY で止める。

SKILL_DIR="home/dot_claude/skills/writing-retro"

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    # auto.sh は同じディレクトリの retro.sh を呼ぶので、配備後の名前で並べる
    BIN="${BATS_TEST_TMPDIR}/skill/scripts"
    mkdir -p "${BIN}" "${BATS_TEST_TMPDIR}/skill/references"
    cp "${REPO_ROOT}/${SKILL_DIR}/scripts/executable_retro.sh" "${BIN}/retro.sh"
    cp "${REPO_ROOT}/${SKILL_DIR}/scripts/executable_auto.sh" "${BIN}/auto.sh"
    cp "${REPO_ROOT}/${SKILL_DIR}/references/"* "${BATS_TEST_TMPDIR}/skill/references/"
    export RETRO_HOME="${BATS_TEST_TMPDIR}/retro"
    export CLAUDE_PROJECTS_DIR="${BATS_TEST_TMPDIR}/projects"
    export RETRO_RULES="${BATS_TEST_TMPDIR}/rules/writing.md"
    export RETRO_NO_NOTIFY=1
    export CLAUDE_LOG="${BATS_TEST_TMPDIR}/claude.log"
    mkdir -p "${CLAUDE_PROJECTS_DIR}/proj"
    # スタブの claude: 引数を記録し、ルールを 1 件足して cursor を進める（スキルの代わり）
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "${STUB}"
    cat >"${STUB}/claude" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${CLAUDE_LOG}"
[[ -n "\${STUB_FAIL:-}" ]] && { echo boom; exit 1; }
[[ -z "\${STUB_NO_EDIT:-}" ]] && echo '- 番号だけで物を指さない' >>"${RETRO_RULES}"
bash "${BIN}/retro.sh" log - <<<'[{"quote":"09","action":"added","rule":"番号だけで物を指さない"}]' >/dev/null
bash "${BIN}/retro.sh" commit >/dev/null
echo "追加 1 件"
STUBEOF
    chmod +x "${STUB}/claude"
    export PATH="${STUB}:${PATH}"
}

# 今日の発言を 1 件置く。指摘なら語の一覧に当たる
write_message() {
    jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "$1" \
        '{type:"user",uuid:"u1",sessionId:"s1",cwd:"/w/repo",timestamp:$t,message:{content:$c}}' \
        >"${CLAUDE_PROJECTS_DIR}/proj/s1.jsonl"
}

@test "auto: valid bash syntax" {
    run bash -n "${BIN}/auto.sh"
    [ "$status" -eq 0 ]
}

@test "auto: does not start claude when there are no candidates" {
    write_message "続けて"
    run bash "${BIN}/auto.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"候補なし"* ]] || false
    [ ! -e "${CLAUDE_LOG}" ]
    # 候補が無くても既読にする（翌日に同じ範囲を読み直さない）
    [ -f "${RETRO_HOME}/state.json" ]
}

@test "auto: runs the skill headlessly with narrowed tools and reports the diff" {
    write_message "09という書き方が分かりにくい"
    run bash "${BIN}/auto.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ルールを変更: 1 件"* ]] || false
    [[ "$output" == *"番号だけで物を指さない"* ]] || false
    grep -qxF -- '-p' "${CLAUDE_LOG}"
    grep -qxF '/writing-retro auto' "${CLAUDE_LOG}"
    grep -qxF 'sonnet' "${CLAUDE_LOG}"
    grep -qxF 'Edit(~/.claude/rules/writing.md)' "${CLAUDE_LOG}"
    grep -qxF "Bash(${BIN}/retro.sh:*)" "${CLAUDE_LOG}"
    # 書き込みや任意のコマンドは許していない
    run grep -xE 'Write|Bash|Bash\(\*\)' "${CLAUDE_LOG}"
    [ "$status" -ne 0 ]
    # ルールファイルが無ければ雛形から作ってから渡す
    grep -qF '# 文章の書き方' "${RETRO_RULES}"
    grep -qF '追加 1 件' "${RETRO_HOME}/last-run.md"
    [ ! -e "${RETRO_HOME}/.auto.lock" ]
}

@test "auto: leaves the cursor alone when claude fails" {
    write_message "09という書き方が分かりにくい"
    run env STUB_FAIL=1 bash "${BIN}/auto.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cursor は進めていません"* ]] || false
    [ ! -e "${RETRO_HOME}/state.json" ]
    [ ! -e "${RETRO_HOME}/.auto.lock" ]
}

@test "auto: fails when the log claims a rule the file does not have" {
    write_message "09という書き方が分かりにくい"
    run env STUB_NO_EDIT=1 bash "${BIN}/auto.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ルールファイルが変わっていない"* ]] || false
}

@test "auto: skips while another run holds the lock" {
    write_message "09という書き方が分かりにくい"
    mkdir -p "${RETRO_HOME}/.auto.lock"
    run bash "${BIN}/auto.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"進行中"* ]] || false
    [ ! -e "${CLAUDE_LOG}" ]
    # 他の実行のロックは消さない
    [ -d "${RETRO_HOME}/.auto.lock" ]
}
