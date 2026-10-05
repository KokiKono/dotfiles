#!/usr/bin/env bats

load ../test_helper

# learning-code スキルの skills.json 読み書きスクリプトを検証する。
# LEARNING_HOME を tmpdir に向けるので ~/.learning は一切触らない。

SCRIPT="home/dot_claude/skills/learning-code/scripts/executable_skills-db.sh"

setup() {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    DB_SCRIPT="${REPO_ROOT}/${SCRIPT}"
    export LEARNING_HOME="${BATS_TEST_TMPDIR}/learning"
    DB="${LEARNING_HOME}/skills.json"
}

@test "skills-db: valid bash syntax" {
    run bash -n "${DB_SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "skills-db: sourcing defines commands without running them" {
    run bash -c "source '${DB_SCRIPT}'; declare -f cmd_init cmd_show cmd_upsert cmd_due >/dev/null && echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [ ! -e "${DB}" ]
}

@test "skills-db: init creates the db from the template and is idempotent" {
    run bash "${DB_SCRIPT}" init
    [ "$status" -eq 0 ]
    [ -f "${DB}" ]
    # 雛形どおりのスキーマであること
    run jq -e '.version == 1 and (.profile.known_stack | index("laravel")) != null and .domains == {}' "${DB}"
    [ "$status" -eq 0 ]
    # 2 回目はコピーし直さない
    echo '{"version":1,"profile":{},"domains":{"kept":{"kind":"language","level":"junior","items":[]}}}' > "${DB}"
    run bash "${DB_SCRIPT}" init
    [ "$status" -eq 0 ]
    run jq -e '.domains | has("kept")' "${DB}"
    [ "$status" -eq 0 ]
}

@test "skills-db: upsert records an item with kind and note" {
    bash "${DB_SCRIPT}" init
    run bash "${DB_SCRIPT}" upsert ruby "block and yield" junior "did not mention Proc" "PR #1" language
    [ "$status" -eq 0 ]
    run jq -r '.domains.ruby.kind' "${DB}"
    [ "$output" = "language" ]
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "junior" ]
    run jq -r '.domains.ruby.items[0].note' "${DB}"
    [ "$output" = "did not mention Proc" ]
    run jq -r '.domains.ruby.items | length' "${DB}"
    [ "$output" = "1" ]
}

@test "skills-db: promotion needs two consecutive higher judgements" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby topic junior "" "PR #1" language
    # 1 回目の上振れは据え置き、last_judged にだけ残る
    bash "${DB_SCRIPT}" upsert ruby topic senior "" "PR #2"
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "junior" ]
    run jq -r '.domains.ruby.items[0].last_judged' "${DB}"
    [ "$output" = "senior" ]
    # 2 回連続で 1 段階だけ昇格
    bash "${DB_SCRIPT}" upsert ruby topic senior "" "review"
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "senior" ]
}

@test "skills-db: promotion never skips a level" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby topic beginner "" "PR #1" language
    bash "${DB_SCRIPT}" upsert ruby topic professional "" "PR #2"
    bash "${DB_SCRIPT}" upsert ruby topic professional "" "PR #3"
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "junior" ]
}

@test "skills-db: demotion drops one level immediately" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby topic senior "" "PR #1" language
    bash "${DB_SCRIPT}" upsert ruby topic beginner "" "PR #2"
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "junior" ]
}

@test "skills-db: upsert rejects an unknown level and leaves the db intact" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby topic junior "" "PR #1" language
    run bash "${DB_SCRIPT}" upsert ruby topic wizard "" "PR #2"
    [ "$status" -ne 0 ]
    run jq -r '.domains.ruby.items[0].level' "${DB}"
    [ "$output" = "junior" ]
}

@test "skills-db: due lists only items past their review interval" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby stale junior "" "PR #1" language
    bash "${DB_SCRIPT}" upsert ruby fresh senior "" "PR #1"
    jq '(.domains.ruby.items[] | select(.topic == "stale")).last_tested = "2020-01-01"' "${DB}" \
        > "${BATS_TEST_TMPDIR}/t.json"
    mv -f "${BATS_TEST_TMPDIR}/t.json" "${DB}"
    run bash "${DB_SCRIPT}" due
    [ "$status" -eq 0 ]
    [[ "$output" == *"stale"* ]]
    [[ "$output" != *"fresh"* ]]
    # 領域で絞れること
    run bash "${DB_SCRIPT}" due rspec
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "skills-db: show renders a table for all domains and for one domain" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert ruby "block and yield" junior "note here" "PR #1" language
    bash "${DB_SCRIPT}" upsert rspec "let and let bang" senior "" "PR #2" framework
    run bash "${DB_SCRIPT}" show
    [ "$status" -eq 0 ]
    [[ "$output" == *"ruby"* ]]
    [[ "$output" == *"rspec"* ]]
    run bash "${DB_SCRIPT}" show ruby
    [ "$status" -eq 0 ]
    [[ "$output" == *"block and yield"* ]]
    [[ "$output" == *"note here"* ]]
    # 未知の領域はエラーにする
    run bash "${DB_SCRIPT}" show nope
    [ "$status" -ne 0 ]
}

@test "skills-db: show truncates long notes and --full keeps them" {
    bash "${DB_SCRIPT}" init
    long="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"   # 60 chars
    bash "${DB_SCRIPT}" upsert ruby topic junior "${long}" "PR #1" language
    run bash "${DB_SCRIPT}" show ruby
    [ "$status" -eq 0 ]
    [[ "$output" != *"${long}"* ]]
    [[ "$output" == *"…"* ]]
    run bash "${DB_SCRIPT}" show --full ruby
    [ "$status" -eq 0 ]
    [[ "$output" == *"${long}"* ]]
    # メモは一番右の列に置く（長くても他の列が崩れないように）
    [[ "$output" =~ 出典[[:space:]]+メモ ]]
}

@test "skills-db: show rejects an unknown option" {
    bash "${DB_SCRIPT}" init
    run bash "${DB_SCRIPT}" show --nope
    [ "$status" -ne 0 ]
}

@test "skills-db: init creates the input_logs directory" {
    bash "${DB_SCRIPT}" init
    [ -d "${LEARNING_HOME}/input_logs" ]
    run bash "${DB_SCRIPT}" logs-dir
    [ "$status" -eq 0 ]
    [ "$output" = "${LEARNING_HOME}/input_logs" ]
}

@test "skills-db: tested lists only items measured on the given day" {
    bash "${DB_SCRIPT}" init
    bash "${DB_SCRIPT}" upsert jq today_topic beginner "stuck here" "PR #24" language
    bash "${DB_SCRIPT}" upsert jq old_topic senior "" "PR #1"
    jq '(.domains.jq.items[] | select(.topic == "old_topic")).last_tested = "2020-01-01"' "${DB}" \
        > "${BATS_TEST_TMPDIR}/t.json"
    mv -f "${BATS_TEST_TMPDIR}/t.json" "${DB}"
    # 既定は今日
    run bash "${DB_SCRIPT}" tested
    [ "$status" -eq 0 ]
    [[ "$output" == *"today_topic"* ]]
    [[ "$output" != *"old_topic"* ]]
    # 判定の根拠も返す（COB の振り返りで使う）
    [[ "$output" == *"stuck here"* ]]
    # 日付を指定できる
    run bash "${DB_SCRIPT}" tested 2020-01-01
    [ "$status" -eq 0 ]
    [[ "$output" == *"old_topic"* ]]
    [[ "$output" != *"today_topic"* ]]
}

@test "skills-db: show on an empty db does not fail" {
    bash "${DB_SCRIPT}" init
    run bash "${DB_SCRIPT}" show
    [ "$status" -eq 0 ]
}
