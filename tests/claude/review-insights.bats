#!/usr/bin/env bats

load ../test_helper

# review-insights スキルの補助スクリプトを検証する。
# REVIEW_INSIGHTS_HOME / REVIEW_INSIGHTS_RULES(_DIR) を tmpdir に向けるので、本物の backlog と個人ルールは触らない。
# takt と gh は呼ばない（daily.sh は関数だけを source して確かめる）。

SKILL="home/dot_claude/skills/review-insights"

setup() {
    STACK="${REPO_ROOT}/${SKILL}/scripts/executable_stack.sh"
    DAILY="${REPO_ROOT}/${SKILL}/scripts/executable_daily.sh"
    PATHS="${REPO_ROOT}/${SKILL}/scripts/executable_paths.py"
    export REVIEW_INSIGHTS_HOME="${BATS_TEST_TMPDIR}/data"
    export REVIEW_INSIGHTS_RULES="${BATS_TEST_TMPDIR}/rules.md"
    export REVIEW_INSIGHTS_RULES_DIR="${BATS_TEST_TMPDIR}/rules"
    RULES_DIR="${REVIEW_INSIGHTS_RULES_DIR}"
    mkdir -p "${RULES_DIR}"
    mkdir -p "${REVIEW_INSIGHTS_HOME}/r1"
    cat >"${REVIEW_INSIGHTS_HOME}/config.json" <<'JSON'
{"repos": {"r1": {"slug": "o/r1", "path": "/nonexistent"}}, "self_login": "me", "promote_min": 3}
JSON
    # b-other1: 他人の PR で 1 回 / b-mine: 自分の PR で 1 回 / b-hot: 他人の PR で 3 回
    cat >"${REVIEW_INSIGHTS_HOME}/r1/backlog.json" <<'JSON'
[
 {"id":"b-other1","rule":"他人1","target_file":"CLAUDE.md","status":"stacked","count":1,
  "first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-01T00:00:00Z",
  "occurrences":[{"pr":1,"url":"u1","date":"2026-11-01","excerpt":"e","pr_author":"someone"}]},
 {"id":"b-mine","rule":"自分1","target_file":"CLAUDE.md","status":"stacked","count":1,
  "first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-01T00:00:00Z",
  "occurrences":[{"pr":2,"url":"u2","date":"2026-11-01","excerpt":"e","pr_author":"me"}]},
 {"id":"b-hot","rule":"頻出","target_file":"CLAUDE.md","status":"stacked","count":3,
  "first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-01T00:00:00Z",
  "occurrences":[{"pr":3,"url":"u3","date":"2026-11-01","excerpt":"e","pr_author":"x"}]}
]
JSON
    printf '# 個人ルール\n\n## 手書きの節\n\n- 手で書いたルール\n' >"${REVIEW_INSIGHTS_RULES}"
}

@test "review-insights: scripts have valid bash syntax" {
    for f in "${REPO_ROOT}/${SKILL}"/scripts/*.sh; do
        run bash -n "$f"
        [ "$status" -eq 0 ]
    done
}

@test "review-insights list: a single comment on my own PR is a candidate" {
    run bash "${STACK}" list r1
    [ "$status" -eq 0 ]
    [ "$(jq -r 'map(.id) | sort | join(",")' <<<"$output")" = "b-hot,b-mine" ]
}

@test "review-insights decide: scoped rules get their own file with paths frontmatter" {
    printf '[{"id":"b-mine","verdict":"adopt","section":"モデル","rule":"整えた自分1","paths":["**/app/models/**/*.rb"]},
             {"id":"b-hot","verdict":"reject","reason":"既出"}]' >"${BATS_TEST_TMPDIR}/d.json"
    run bash "${STACK}" decide r1 "${BATS_TEST_TMPDIR}/d.json"
    [ "$status" -eq 0 ]
    f="$(ls "${RULES_DIR}"/auto-r1-*.md)"
    [ "$(echo "$f" | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(head -1 "$f")" = "---" ]
    grep -qxF '  - "**/app/models/**/*.rb"' "$f"
    grep -qxF '## モデル' "$f"
    grep -qxF -- '- 整えた自分1' "$f"
    run grep -rq '頻出' "${RULES_DIR}"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.[] | select(.id=="b-hot") | .status' "${REVIEW_INSIGHTS_HOME}/r1/backlog.json")" = "rejected" ]
}

@test "review-insights decide: cross-cutting rules go to an always-loaded file capped by always_max" {
    # paths の無いルールは常に読まれるので、件数の多い順に always_max 件で切る
    jq '.always_max = 1' "${REVIEW_INSIGHTS_HOME}/config.json" >"${BATS_TEST_TMPDIR}/c" \
        && mv "${BATS_TEST_TMPDIR}/c" "${REVIEW_INSIGHTS_HOME}/config.json"
    printf '[{"id":"b-mine","verdict":"adopt","section":"S","rule":"R-mine","paths":[]},
             {"id":"b-hot","verdict":"adopt","section":"S","rule":"R-hot","paths":[]}]' >"${BATS_TEST_TMPDIR}/d.json"
    bash "${STACK}" decide r1 "${BATS_TEST_TMPDIR}/d.json"
    f="${RULES_DIR}/auto-r1-common.md"
    [ "$(head -1 "$f")" != "---" ]
    grep -qxF -- '- R-hot' "$f"
    run grep -q 'R-mine' "$f"
    [ "$status" -ne 0 ]
}

@test "review-insights decide: does not overwrite entries already decided by hand" {
    bash "${STACK}" promote r1 b-mine rejected
    printf '[{"id":"b-mine","verdict":"adopt","section":"S","rule":"R","paths":[]}]' >"${BATS_TEST_TMPDIR}/d.json"
    bash "${STACK}" decide r1 "${BATS_TEST_TMPDIR}/d.json"
    [ "$(jq -r '.[] | select(.id=="b-mine") | .status' "${REVIEW_INSIGHTS_HOME}/r1/backlog.json")" = "rejected" ]
    run ls "${RULES_DIR}"/auto-r1-*.md
    [ "$status" -ne 0 ]
}

@test "review-insights mechanize: adopted rules keep the prose until mechanized" {
    # チェックが入るまでは文章のルールも残し、入ったら文章の方を外す（二重管理をやめる）
    # 形の崩れた mechanize は捨てるが、ルールの採用は止めない
    printf '[{"id":"b-hot","verdict":"adopt","section":"S","rule":"R-hot","paths":[],
              "mechanize":{"kind":"lint","how":"禁止する"}},
             {"id":"b-mine","verdict":"adopt","section":"S","rule":"R-mine","paths":["**/a/**"],
              "mechanize":{"kind":"grep"}}]' >"${BATS_TEST_TMPDIR}/d.json"
    bash "${STACK}" decide r1 "${BATS_TEST_TMPDIR}/d.json"
    grep -qxF -- '- R-hot' "${RULES_DIR}/auto-r1-common.md"
    grep -qxF -- '  - lint: 禁止する' "${REVIEW_INSIGHTS_HOME}/r1/backlog.md"
    [ "$(jq -c '.[] | select(.id=="b-mine") | [.status, .mechanize]' "${REVIEW_INSIGHTS_HOME}/r1/backlog.json")" = '["promoted",null]' ]
    run bash "${STACK}" mechanize r1
    [ "$(jq -r 'map(.id) | join(",")' <<<"$output")" = "b-hot" ]

    bash "${STACK}" promote r1 b-hot mechanized
    run ls "${RULES_DIR}/auto-r1-common.md"
    [ "$status" -ne 0 ]
    run bash "${STACK}" mechanize r1
    [ "$output" = "[]" ]
    [ "$(jq -r '.[] | select(.id=="b-hot") | .status' "${REVIEW_INSIGHTS_HOME}/r1/backlog.json")" = "mechanized" ]
    grep -qxF -- '- R-hot → lint: 禁止する' "${REVIEW_INSIGHTS_HOME}/r1/backlog.md"
}

@test "review-insights mechanize: can be attached later only to promoted rules" {
    run bash "${STACK}" mechanize-set r1 b-hot lint x
    [ "$status" -ne 0 ]
    run bash "${STACK}" promote r1 b-hot mechanized
    [ "$status" -ne 0 ]
    bash "${STACK}" promote r1 b-hot
    # 打ち間違えた status と、機械化の案が無いままの mechanized は受け付けない（ルールが黙って消えるため）
    run bash "${STACK}" promote r1 b-hot mechanised
    [ "$status" -ne 0 ]
    run bash "${STACK}" promote r1 b-hot mechanized
    [ "$status" -ne 0 ]
    [ "$(jq -r '.[] | select(.id=="b-hot") | .status' "${REVIEW_INSIGHTS_HOME}/r1/backlog.json")" = "promoted" ]
    run bash "${STACK}" mechanize-set r1 b-hot regex x
    [ "$status" -ne 0 ]
    run bash "${STACK}" mechanize-set r1 b-hot ci ""
    [ "$status" -ne 0 ]
    run bash "${STACK}" mechanize-set r1 b-hot ci "差分を落とす"
    [ "$status" -eq 0 ]
    [ "$(jq -c '.mechanize' <<<"$output")" = '{"kind":"ci","how":"差分を落とす"}' ]
}

@test "review-insights rules: rejecting the last rule removes its file and keeps others" {
    printf '[{"id":"b-mine","verdict":"adopt","section":"S","rule":"R","paths":["**/a/**"]}]' >"${BATS_TEST_TMPDIR}/d.json"
    printf 'hand\n' >"${RULES_DIR}/hand-written.md"
    bash "${STACK}" decide r1 "${BATS_TEST_TMPDIR}/d.json"
    bash "${STACK}" promote r1 b-mine rejected
    bash "${STACK}" rules r1
    run ls "${RULES_DIR}"/auto-r1-*.md
    [ "$status" -ne 0 ]
    [ -f "${RULES_DIR}/hand-written.md" ]
}

@test "review-insights rules: strips the legacy single-file block, keeps hand-written text" {
    printf '\n<!-- review-insights:auto r1 -->\n## old\n- 旧ルール\n<!-- /review-insights:auto r1 -->\n\n## 後ろの手書き\n' \
        >>"${REVIEW_INSIGHTS_RULES}"
    bash "${STACK}" rules r1
    run grep -q '旧ルール' "${REVIEW_INSIGHTS_RULES}"
    [ "$status" -ne 0 ]
    grep -qxF -- '- 手で書いたルール' "${REVIEW_INSIGHTS_RULES}"
    grep -qxF '## 後ろの手書き' "${REVIEW_INSIGHTS_RULES}"
}

@test "review-insights paths: derives globs from the target rule file, anchored with **/" {
    A="${BATS_TEST_TMPDIR}/agent"
    mkdir -p "$A/.claude/rules"
    printf -- '---\npaths:\n  - "app/models/**/*.rb"\n  - "**/*_model.rb"\n---\nbody\n' >"$A/.claude/rules/model.md"
    printf -- '---\npaths: apps/a/**, packages/b/**\n---\n' >"$A/.claude/rules/inline.md"
    run python3 "${PATHS}" target "$A" .claude/rules/model.md
    [ "$output" = '["**/app/models/**/*.rb", "**/*_model.rb"]' ]
    run python3 "${PATHS}" target "$A" .claude/rules/inline.md
    [ "$output" = '["**/apps/a/**", "**/packages/b/**"]' ]
    run python3 "${PATHS}" target "$A" apps/web/CLAUDE.md
    [ "$output" = '["**/apps/web/**"]' ]
    # ルートの agent ファイル向けは横断ルール（paths なし）
    run python3 "${PATHS}" target "$A" AGENTS.md
    [ "$output" = '[]' ]
}

@test "review-insights paths: match follows rules glob semantics" {
    printf '[{"id":"m","paths":["**/app/models/**/*.rb"]},{"id":"t","paths":["**/*.{ts,tsx}"]},
             {"id":"x","paths":["**/db/migrate/**"]},{"id":"c","paths":[]}]' >"${BATS_TEST_TMPDIR}/r.json"
    printf 'app/models/user.rb\nweb/src/a.tsx\n' >"${BATS_TEST_TMPDIR}/f.txt"
    run python3 "${PATHS}" match "${BATS_TEST_TMPDIR}/r.json" "${BATS_TEST_TMPDIR}/f.txt"
    [ "$output" = '["m", "t"]' ]
}

@test "review-insights paths: backfill fills only promoted auto entries missing paths" {
    printf '[{"id":"a","status":"promoted","auto":true,"target_file":"apps/w/CLAUDE.md"},
             {"id":"b","status":"promoted","auto":true,"target_file":"x","paths":["keep"]},
             {"id":"c","status":"stacked","target_file":"apps/w/CLAUDE.md"}]' >"${BATS_TEST_TMPDIR}/bl.json"
    run python3 "${PATHS}" backfill "${BATS_TEST_TMPDIR}/bl.json" "${BATS_TEST_TMPDIR}"
    [ "$output" = "1" ]
    [ "$(jq -c '[.[] | .paths]' "${BATS_TEST_TMPDIR}/bl.json")" = '[["**/apps/w/**"],["keep"],null]' ]
}

@test "review-insights daily: merges triage noise and fills pr_author from pending" {
    D="${REVIEW_INSIGHTS_HOME}/r1"
    printf '%s\n' '{"id":"inline:1","pr_author":"me"}' '{"id":"inline:2","pr_author":"x"}' >"$D/pending.jsonl"
    printf '{"noise":[{"id":"inline:2","reason":"謝辞"}]}' >"$D/triage.json"
    printf '[{"verdict":"stack","comment_ids":["inline:1"],"rule":"R","evidence":{"pr":1}}]' >"$D/classified.json"
    run bash -c "source '${DAILY}'; merge_classified '$D' > '$D/m.json' && validate_coverage '$D' '$D/m.json'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.[0].evidence.pr_author' "$D/m.json")" = "me" ]
    [ "$(jq -r '.[1].verdict' "$D/m.json")" = "noise" ]
}

@test "review-insights daily: coverage check rejects missing and duplicated ids" {
    D="${REVIEW_INSIGHTS_HOME}/r1"
    printf '%s\n' '{"id":"inline:1"}' '{"id":"inline:2"}' >"$D/pending.jsonl"
    printf '[{"verdict":"noise","comment_ids":["inline:1"]}]' >"$D/missing.json"
    printf '[{"verdict":"noise","comment_ids":["inline:1","inline:2"]},{"verdict":"noise","comment_ids":["inline:2"]}]' >"$D/dup.json"
    run bash -c "source '${DAILY}'; validate_coverage '$D' '$D/missing.json'"
    [ "$status" -ne 0 ]
    run bash -c "source '${DAILY}'; validate_coverage '$D' '$D/dup.json'"
    [ "$status" -ne 0 ]
}

@test "review-insights daily: decisions must cover exactly the candidates" {
    printf '[{"id":"a"},{"id":"b"}]' >"${BATS_TEST_TMPDIR}/c.json"
    printf '[{"id":"a","verdict":"adopt"},{"id":"b","verdict":"reject"}]' >"${BATS_TEST_TMPDIR}/ok.json"
    printf '[{"id":"a","verdict":"adopt"}]' >"${BATS_TEST_TMPDIR}/ng.json"
    run bash -c "source '${DAILY}'; validate_decisions '${BATS_TEST_TMPDIR}/c.json' '${BATS_TEST_TMPDIR}/ok.json'"
    [ "$status" -eq 0 ]
    run bash -c "source '${DAILY}'; validate_decisions '${BATS_TEST_TMPDIR}/c.json' '${BATS_TEST_TMPDIR}/ng.json'"
    [ "$status" -ne 0 ]
}

@test "review-insights takt: every step routed in runtime.yaml exists in a workflow" {
    # runtime.yaml の targets.steps は <workflow 名>/<step 名>。WF 側の改名に追従しないと黙って既定の haiku に落ちる
    T="${REPO_ROOT}/${SKILL}/takt"
    for key in $(sed -n 's/^      \([a-z-]*\/[a-z-]*\):$/\1/p' "$T/runtime.yaml"); do
        wf="${key%%/*}"; step="${key#*/}"
        grep -qxF "name: ${wf}" "$T/${wf}.yaml"
        grep -qxF "  - name: ${step}" "$T/${wf}.yaml"
    done
    [ -n "$(sed -n 's/^      \([a-z-]*\/[a-z-]*\):$/\1/p' "$T/runtime.yaml")" ]
}

@test "review-insights takt: workflows never set a model directly" {
    # step の model / provider は takt のスキーマが拒否する。振り分けは runtime.yaml だけで行う
    run grep -qE '^\s+(model|provider):' "${REPO_ROOT}/${SKILL}"/takt/review-*.yaml
    [ "$status" -ne 0 ]
}

@test "review-insights fetch: drops the PR author's own comments unless they reply in a thread" {
    # jqlib は fetch-comments.sh に埋め込まれているので、定義部分だけを抜き出して使う
    f="${REPO_ROOT}/${SKILL}/scripts/executable_fetch-comments.sh"
    lib="$(sed -n "/^jqlib='/,/^'\$/p" "$f" | sed '1s/^jqlib=.//;$d')"
    run jq -nr "$lib"'
      [{author:"a", pr_author:"a", in_reply_to_id:null,       body:"【1】配信失敗を先に記録する理由の解説です"},
       {author:"a", pr_author:"a", in_reply_to_id:"inline:1", body:"ご指摘のとおりなので level を分けました"},
       {author:"b", pr_author:"a", in_reply_to_id:null,       body:"この判定だと外部連携の店舗が漏れませんか"},
       {author:"b", pr_author:null, in_reply_to_id:null,      body:"PR の情報が取れなかったときは落とさない"}]
      | map(noise) | map(tostring) | join(",")'
    [ "$status" -eq 0 ]
    [ "$output" = "true,false,false,false" ]
}

@test "review-insights daily: report summarizes per-repo counts, failures and promoted rule changes" {
    export REVIEW_INSIGHTS_WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${REVIEW_INSIGHTS_WORK}"
    # 実行前に promoted だったもの: b-gone（今回なくなる）と b-keep（残る）。
    # b-lint は前回の実行より後に、b-old はそれより前に、手で mechanized にしたもの
    before='[{"id":"b-gone","rule":"外したルール"},{"id":"b-keep","rule":"残るルール"}]'
    jq 'map(if .id == "b-mine" then .status = "promoted" | .auto = true | .rule_final = "足したルール"
            | .mechanize = {"kind":"lint","how":"禁止する"} else . end)
        + [{"id":"b-keep","rule":"残るルール","status":"promoted","auto":true,"count":9},
           {"id":"b-lint","rule":"置き換えたルール","status":"mechanized","mechanized_at":"2026-11-10T05:00:00Z"},
           {"id":"b-old","rule":"前に置き換えたルール","status":"mechanized","mechanized_at":"2026-11-08T05:00:00Z"}]' \
        "${REVIEW_INSIGHTS_HOME}/r1/backlog.json" >"${BATS_TEST_TMPDIR}/b" && mv "${BATS_TEST_TMPDIR}/b" "${REVIEW_INSIGHTS_HOME}/r1/backlog.json"

    run bash -c "source '${DAILY}'
      : > \"\$REPORT\"
      report --arg r r1 '{repo: \$r, fetched: 60, deferred: 475}'
      report --arg r r1 --argjson a '{\"applied\":48,\"stacked\":9,\"dropped\":39,\"backlog_total\":396}' '{repo: \$r, apply: \$a}'
      report_rule_changes r1 '$before' 2026-11-09T00:03:00Z
      report --arg r r2 '{repo: \$r, fetched: 3, deferred: 0}'
      report_fail r2 '取り込みか分類に失敗した'
      report --arg r r2 --argjson a 'not json' '{repo: \$r, apply: \$a}'
      format_report"
    [ "$status" -eq 0 ]
    [[ "$output" == *"日次レポート** :warning: 失敗あり"* ]] || false
    [[ "$output" == *"取得 60 件（持ち越し 475 件）"* ]] || false
    [[ "$output" == *"backlog に積んだ 9 件 / 既出・指摘でないもの 39 件（backlog 計 396 件）"* ]] || false
    [[ "$output" == *":warning: 取り込みか分類に失敗した"* ]] || false
    [[ "$output" == *"追加したルール（1 件）**"$'\n'"• [r1] 足したルール"* ]] || false
    [[ "$output" == *"外したルール（1 件）**"$'\n'"• [r1] 外したルール"* ]] || false
    [[ "$output" == *"チェックに置き換えたルール（1 件）**"$'\n'"• [r1] 置き換えたルール"* ]] || false
    [[ "$output" != *"前に置き換えたルール"* ]] || false
    [[ "$output" == *"チェックに置き換える候補（未対応）1 件"* ]] || false
    [[ "$output" == *"置き換えられそうなもの（1 件）**"$'\n'"• [r1] 足したルール"$'\n'"    → lint: 禁止する"* ]] || false
    [[ "$output" != *"残るルール"* ]] || false
}

@test "review-insights daily: report is posted only when configured, and success needs an OK reply" {
    stub="${BATS_TEST_TMPDIR}/claude"
    cat >"$stub" <<STUB
#!/bin/sh
echo "\$@" >"${BATS_TEST_TMPDIR}/claude.args"; cat >"${BATS_TEST_TMPDIR}/claude.stdin"
printf '{"is_error":false,"result":"%s"}' "\$(cat "${BATS_TEST_TMPDIR}/reply")"
STUB
    chmod +x "$stub"
    export REVIEW_INSIGHTS_CLAUDE="$stub" REVIEW_INSIGHTS_WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${REVIEW_INSIGHTS_WORK}"
    echo '{"repo":"r1","fetched":0,"deferred":0}' >"${REVIEW_INSIGHTS_WORK}/report.jsonl"

    run bash -c "source '${DAILY}'; post_report"
    [ "$status" -eq 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/claude.args" ]

    jq '.slack_report_channel = "C123"' "${REVIEW_INSIGHTS_HOME}/config.json" >"${BATS_TEST_TMPDIR}/c" \
        && mv "${BATS_TEST_TMPDIR}/c" "${REVIEW_INSIGHTS_HOME}/config.json"
    echo OK >"${BATS_TEST_TMPDIR}/reply"
    run bash -c "source '${DAILY}'; post_report"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Slack に報告を投稿した（C123）"* ]] || false
    grep -q 'mcp__claude_ai_Slack__slack_send_message' "${BATS_TEST_TMPDIR}/claude.args"
    grep -q -- '--tools ToolSearch' "${BATS_TEST_TMPDIR}/claude.args"
    grep -q '取得 0 件' "${BATS_TEST_TMPDIR}/claude.stdin"

    # 投稿できなくても claude は正常終了するので、返答で失敗を拾う
    echo 'NG Slack に接続できない' >"${BATS_TEST_TMPDIR}/reply"
    run bash -c "source '${DAILY}'; post_report"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Slack への投稿に失敗: NG Slack に接続できない"* ]] || false
}
