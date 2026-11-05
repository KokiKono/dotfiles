#!/usr/bin/env bash
# Claude Code のセッション記録から、前回の振り返り以降にユーザーが打った発言を抜き出す。
# writing-retro スキルから呼ばれる。指摘かどうかの判定とルールへの書き戻しはスキル本文の担当。
#
# cursor（state.json の since）は commit でしか進めない。判定の途中で止まっても、
# 次回は同じ範囲を読み直すだけで発言を取りこぼさない。
set -Eeuo pipefail

RETRO_HOME="${RETRO_HOME:-${HOME}/.claude/writing-retro}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
STATE="${RETRO_HOME}/state.json"
PENDING="${RETRO_HOME}/pending.jsonl"
PENDING_META="${RETRO_HOME}/pending.meta.json"
LOG="${RETRO_HOME}/log.jsonl"
RULES="${RETRO_RULES:-${HOME}/.claude/rules/writing.md}"
# rules/writing.md は全セッションで読み込まれるので、ルールが増えるほど毎回のトークンが増え、
# 他の指示も埋もれる。この件数を超えたら足す前にまとめる
RULES_LIMIT="${RETRO_RULES_LIMIT:-40}"

# 1 件あたりの文字数。貼り付けたログや issue 本文で 1 万字を超える発言があるので切る。
# 指摘は短い（中央値 30 字前後）ので 400 字あれば判定に足りる。直前の発話は、何を書いたときの
# 指摘かが分かる程度に添える。ここで足りれば Claude が context を引きに行かずに済む。
USER_CHARS="${RETRO_USER_CHARS:-400}"
PREV_CHARS="${RETRO_PREV_CHARS:-600}"
# これより長い発言は語に当たっても候補にしない。貼り付けた資料や hello-run の初期プロンプトで、
# 指摘は長くても 300 字程度に収まる
MAX_CHARS="${RETRO_MAX_CHARS:-600}"
LEXICON="${RETRO_LEXICON:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../references/lexicon.txt}"

die() { echo "retro: $*" >&2; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 初回は当日 0 時（ローカル）から読む。過去分は --since で明示して読む。
today_start_iso() { date -u -r "$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 00:00:00" +%s)" +%Y-%m-%dT%H:%M:%SZ; }

# --since 7d のような相対指定を ISO に直す
resolve_since() {
    local s="$1"
    if [[ "$s" =~ ^([0-9]+)d$ ]]; then
        date -u -v-"${BASH_REMATCH[1]}"d +%Y-%m-%dT%H:%M:%SZ
    else
        echo "$s"
    fi
}

stored_since() {
    if [[ -f "${STATE}" ]]; then
        jq -r '.since // empty' "${STATE}"
    fi
}

# 1 ファイル分。直前の assistant の発話と、そのターンで何を書いたか（medium）を発言に添える。
# 除外するもの: subagent（isSidechain）、スキル本文や hook の注入（isMeta）、
# ツール結果（text を持たない）、スラッシュコマンドやタスク通知のラッパー、claude -p（sdk-cli）、
# コンパクション後の要約（isCompactSummary）。
extract_file() {
    local file="$1" since="$2" lex="$3"
    jq -nc --arg since "${since}" --arg file "${file}" --arg lex "${lex}" \
        --argjson uc "${USER_CHARS}" --argjson pc "${PREV_CHARS}" --argjson mc "${MAX_CHARS}" '
      def text_of: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
      def medium_of: .name as $n | (.input // {}) as $i |
        if ($n | test("notion-")) then "notion"
        elif ($n | test("slack_")) then "slack"
        elif ($n | test("Claude_Docs|^Artifact$")) then "doc"
        elif $n == "Bash" then ($i.command // "" |
          if test("gh pr (create|edit)") then "pr"
          elif test("gh (pr|issue) comment|gh issue (create|edit)|gh api .*comments") then "github"
          elif test("git commit") then "commit" else null end)
        elif ($n == "Write" or $n == "Edit") and ($i.file_path // "" | test("\\.md$")) then "md"
        else null end;
      reduce inputs as $e ({last: "", medium: null, out: []};
        if ($e.isSidechain // false) or ($e.entrypoint // "cli") == "sdk-cli" then .
        elif $e.type == "assistant" then
          ($e.message.content | text_of) as $t
          | ([$e.message.content[]? | select(.type == "tool_use") | medium_of | select(. != null)] | last) as $m
          | (if $t == "" then . else .last = $t end) | (if $m == null then . else .medium = $m end)
        elif $e.type == "user" and (($e.isMeta // false) or ($e.isCompactSummary // false) | not) then
          ($e.message.content | text_of) as $c
          | if $c == "" or ($c | test("^\\s*<(command-|local-command|task-notification|system-reminder)")) then .
            elif ($e.timestamp // "") <= $since then .medium = null
            else .out += [{
              ts: $e.timestamp, session: $e.sessionId, cwd: $e.cwd, uuid: $e.uuid, file: $file,
              hit: ($lex != "" and ($c | length) <= $mc and ($c | test($lex))), medium: (.medium // "chat"),
              user: $c[0:$uc], user_truncated: (($c | length) > $uc),
              prev: (.last | if length > $pc then .[-$pc:] else . end)
            }] | .medium = null
            end
        else . end)
      | .out[]' "${file}" 2>/dev/null || true
}

# lexicon.txt を 1 本の正規表現にする
lexicon_regex() {
    [[ -f "${LEXICON}" ]] || die "lexicon not found: ${LEXICON}"
    grep -v -e '^#' -e '^[[:space:]]*$' "${LEXICON}" | paste -sd '|' -
}

cmd_extract() {
    local since="" until all=0 lex
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since) since="$(resolve_since "${2:?--since needs a value}")"; shift 2 ;;
            --all) all=1; shift ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [[ -n "${since}" ]] || since="$(stored_since)"
    [[ -n "${since}" ]] || since="$(today_start_iso)"
    until="$(now_iso)"
    [[ -d "${PROJECTS_DIR}" ]] || die "projects dir not found: ${PROJECTS_DIR}"
    mkdir -p "${RETRO_HOME}"
    lex="$(lexicon_regex)"

    # 記録は全体で 1GB を超えるので、更新時刻で先に絞ってから jq に渡す
    local ref files=0
    ref="$(mktemp "${RETRO_HOME}/.ref.XXXXXX")"
    touch -d "${since}" "${ref}"
    : >"${PENDING}"
    while IFS= read -r -d '' f; do
        files=$((files + 1))
        extract_file "$f" "${since}" "${lex}" >>"${PENDING}"
    done < <(find "${PROJECTS_DIR}" -name '*.jsonl' -not -path '*/subagents/*' -newer "${ref}" -print0)
    rm -f "${ref}"

    # 語に当たらない発言は Claude に渡さない（1 週間で 612 件 → 70 件前後）。
    # 判定を全部 Claude に任せると、毎日 150 件前後を読ませることになる。
    # 時系列に並べ直すのも同時に行う（ファイル単位で読むのでセッションをまたぐと順序が崩れる）
    local tmp scanned
    scanned="$(wc -l <"${PENDING}" | tr -d ' ')"
    tmp="$(mktemp "${RETRO_HOME}/.pending.XXXXXX")"
    jq -sc --argjson all "${all}" 'map(select($all == 1 or .hit)) | sort_by(.ts) | .[]' "${PENDING}" >"${tmp}" \
        && mv -f "${tmp}" "${PENDING}"

    jq -n --arg since "${since}" --arg until "${until}" --arg pending "${PENDING}" \
        --argjson files "${files}" --argjson scanned "${scanned}" \
        --argjson messages "$(wc -l <"${PENDING}" | tr -d ' ')" \
        '{since: $since, until: $until, files: $files, scanned: $scanned, messages: $messages, pending: $pending}' \
        | tee "${PENDING_META}"
}

# 判定用の一覧。1 件 2 行で「id 時刻 媒体 リポジトリ 発言」と、直前の AI の発話の末尾。
# --all で抜き出したときは件数が多いので、--short で発言の行だけにする
cmd_list() {
    local short=0
    [[ "${1:-}" == "--short" ]] && short=1
    [[ -f "${PENDING}" ]] || die "no pending; run extract first"
    jq -r --argjson short "${short}" '
      ([.uuid[0:8], .ts[5:16], .medium, (.cwd // "" | split("/") | last),
        (.user | gsub("\\s+"; " ")) + (if .user_truncated then " …" else "" end)] | @tsv)
      + (if $short == 1 then "" else "\n    ← " + (.prev | gsub("\\s+"; " ")) end)' "${PENDING}"
}

# 指摘の対象になった assistant の発話を、切らずに前から n 件出す。id は list の先頭 8 文字でよい
cmd_context() {
    local id="${1:?usage: context <id> [n]}" n="${2:-1}" uuid file
    [[ -f "${PENDING}" ]] || die "no pending; run extract first"
    read -r uuid file < <(jq -r --arg u "${id}" 'select(.uuid | startswith($u)) | "\(.uuid) \(.file)"' "${PENDING}" | head -1) || true
    [[ -n "${file:-}" ]] || die "id not in pending: ${id}"
    jq -nr --arg u "${uuid}" --argjson n "${n}" '
      def text_of: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
      first(foreach inputs as $e ({texts: [], hit: null};
          if .hit != null then .
          elif ($e.isSidechain // false) then .
          elif $e.uuid == $u then .hit = ($e.message.content | text_of)
          elif $e.type == "assistant" then
            ($e.message.content | text_of) as $t | if $t == "" then . else .texts += [$t] end
          else . end;
          select(.hit != null)))
      | (.texts[-$n:] | map("--- assistant ---\n" + .) | join("\n")) + "\n--- user ---\n" + .hit
    ' "${file}"
}

# 判定が済んだ範囲を既読にする。log の追記が済んでから呼ぶこと
cmd_commit() {
    [[ -f "${PENDING_META}" ]] || die "no pending; run extract first"
    local until
    until="$(jq -r '.until' "${PENDING_META}")"
    jq -n --arg s "${until}" '{since: $s}' >"${STATE}"
    rm -f "${PENDING}" "${PENDING_META}"
    echo "since: ${until}"
}

# 判定結果（JSON 配列のファイル）を log.jsonl に追記する。日付はここで付ける
cmd_log() {
    local f="${1:?usage: log <entries.json>}"
    jq -e 'type == "array" and all(.[]; has("quote") and has("action"))' "$f" >/dev/null \
        || die "entries must be an array of objects with quote and action"
    mkdir -p "${RETRO_HOME}"
    jq -c --arg d "$(date +%Y-%m-%d)" '.[] | {date: $d} + .' "$f" >>"${LOG}"
    echo "logged: $(jq 'length' "$f")"
}

# ルールごとの指摘回数。2 回以上あるものはルールが効いていない
cmd_stats() {
    [[ -f "${LOG}" ]] || { echo "[]"; return 0; }
    jq -sc '[.[] | select(.rule != null and .rule != "")] | group_by(.rule)
        | map({rule: .[0].rule, count: length, last: (map(.date) | max)})
        | sort_by(-.count)' "${LOG}"
}

# ルールの件数と文字数。over が true なら、足す前に似たルールをまとめる
cmd_budget() {
    [[ -f "${RULES}" ]] || die "rules not found: ${RULES}"
    jq -n --argjson rules "$(grep -c '^- ' "${RULES}" || true)" \
        --argjson chars "$(wc -m <"${RULES}" | tr -d ' ')" --argjson limit "${RULES_LIMIT}" \
        '{rules: $rules, chars: $chars, limit: $limit, over: ($rules > $limit)}'
}

usage() {
    cat <<'EOF'
usage: retro.sh <command>
  extract [--since ISO|Nd] [--all]
                             前回以降のユーザー発言のうち lexicon に当たるものを pending.jsonl に出す
                             （--all は全件。cursor は進めない）
  list [--short]             pending を「id 時刻 媒体 リポジトリ 発言」と直前の AI の発話で出す
  context <id> [n]           その発言の直前の assistant 発話を n 件、切らずに出す
  log <entries.json>         判定結果を log.jsonl に追記する
                             [{"quote","action":"added|strengthened|skipped","rule","reason","session"}]
  commit                     cursor を extract 時点まで進める
  stats                      ルールごとの指摘回数
  budget                     rules/writing.md のルール件数と上限
EOF
}

main() {
    command -v jq >/dev/null 2>&1 || die "jq is required"
    local cmd="${1:-}"
    shift || true
    case "${cmd}" in
        extract) cmd_extract "$@" ;;
        list) cmd_list "$@" ;;
        context) cmd_context "$@" ;;
        commit) cmd_commit ;;
        log) cmd_log "$@" ;;
        stats) cmd_stats ;;
        budget) cmd_budget ;;
        *) usage; [[ -z "${cmd}" ]] || exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
