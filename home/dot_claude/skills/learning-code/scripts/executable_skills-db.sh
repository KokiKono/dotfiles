#!/usr/bin/env bash
# ~/.learning/skills.json の読み書き。learning-code スキルから呼ばれる。
#
# ここに置いてあるのは「毎回同じ手順で壊れずに書ける」部分だけ。
# 何を出題するか・回答をどう判定するかはスキル本文とリファレンスの担当。
#
# レベル昇降のルール（references/schema.md と対応）:
#   - 初回は判定をそのまま採用する
#   - 昇格は同一 topic で 2 回連続で上位判定が出たときのみ、1 段階だけ
#   - 降格は 1 回で 1 段階（説明できなくなっているなら即座に落とす）
set -Eeuo pipefail

LEARNING_HOME="${LEARNING_HOME:-${HOME}/.learning}"
DB="${LEARNING_HOME}/skills.json"
LOGS_DIR="${LEARNING_HOME}/input_logs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../references/skills.template.json"

# jq 側で使い回す共通定義。レベルの順序・日本語表示・再出題間隔はここが唯一の定義。
read -r -d '' JQ_LIB <<'JQ' || true
def rank: {"beginner":1,"junior":2,"senior":3,"professional":4}[.] // 0;
def ja: {"beginner":"ビギナー","junior":"ジュニア","senior":"シニア","professional":"プロフェッショナル"}[.] // .;
def unrank: {"1":"beginner","2":"junior","3":"senior","4":"professional"}[.|tostring] // "beginner";
def interval: {"beginner":7,"junior":7,"senior":30,"professional":90}[.] // 7;
def days_since($now): ($now - (strptime("%Y-%m-%d")|mktime)) / 86400 | floor;
# 領域のレベルは項目レベルの中央値（低いほう寄り）。項目が無ければ既存値を使う。
def domain_level: (map(.level|rank)|sort) as $r
  | if ($r|length) == 0 then null else ($r[(($r|length)-1)/2|floor] | unrank) end;
JQ

die() { echo "skills-db: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

today() { date +%Y-%m-%d; }

# jq の結果を一時ファイル経由で差し替える。jq が失敗したら元ファイルは触らない。
write_db() {
    local tmp
    tmp="$(mktemp "${LEARNING_HOME}/.skills.json.XXXXXX")"
    if jq "$@" "${DB}" >"${tmp}"; then
        mv -f "${tmp}" "${DB}"
    else
        rm -f "${tmp}"
        die "jq failed; ${DB} is unchanged"
    fi
}

cmd_init() {
    mkdir -p "${LEARNING_HOME}" "${LOGS_DIR}"
    if [[ -f "${DB}" ]]; then
        echo "exists: ${DB}"
        return 0
    fi
    [[ -f "${TEMPLATE}" ]] || die "template not found: ${TEMPLATE}"
    cp "${TEMPLATE}" "${DB}"
    echo "created: ${DB}"
}

require_db() {
    has_jq || die "jq is required (brew install jq)"
    [[ -f "${DB}" ]] || cmd_init >/dev/null
}

# upsert <domain> <topic> <level> [note] [source] [kind]
cmd_upsert() {
    local domain="${1:-}" topic="${2:-}" judged="${3:-}" note="${4:-}" source="${5:-}" kind="${6:-}"
    [[ -n "${domain}" && -n "${topic}" && -n "${judged}" ]] \
        || die "usage: upsert <domain> <topic> <level> [note] [source] [kind]"
    case "${judged}" in
        beginner|junior|senior|professional) ;;
        *) die "invalid level: ${judged}" ;;
    esac
    require_db
    write_db "${JQ_LIB}"'
      .domains[$d] //= {kind: ($kind | if . == "" then "unknown" else . end), level: $judged, items: []}
      | (if $kind != "" then .domains[$d].kind = $kind else . end)
      | .domains[$d].items as $items
      | ($items | map(.topic == $t) | index(true)) as $i
      | (if $i == null then null else $items[$i] end) as $prev
      | (
          if $prev == null then ($judged|rank)
          elif ($judged|rank) > ($prev.level|rank) then
            # 2 回連続で上位判定なら 1 段階だけ上げる
            (if (($prev.last_judged // $prev.level)|rank) > ($prev.level|rank)
             then ($prev.level|rank) + 1 else ($prev.level|rank) end)
          elif ($judged|rank) < ($prev.level|rank) then ($prev.level|rank) - 1
          else ($prev.level|rank) end
        ) as $next
      | {topic: $t, level: ($next|unrank), last_judged: $judged, last_tested: $today,
         note: $n, source: $s} as $item
      | .domains[$d].items = (if $i == null then $items + [$item] else ($items | .[$i] = $item) end)
      | .domains[$d].level = ((.domains[$d].items | domain_level) // .domains[$d].level)
      | .domains[$d].assessed_at = $today
      | .updated_at = $today
    ' --arg d "${domain}" --arg t "${topic}" --arg judged "${judged}" \
      --arg n "${note}" --arg s "${source}" --arg kind "${kind}" --arg today "$(today)"
    jq -r "${JQ_LIB}"'
      .domains[$d] as $dom
      | ($dom.items[] | select(.topic == $t)) as $it
      | "\($d) / \($t): \($it.level|ja)  （領域: \($dom.level|ja)）"
    ' --arg d "${domain}" --arg t "${topic}" "${DB}"
}

# due [domain] — 再出題の対象を TSV（domain / topic / level / last_tested / 経過日数 / note）で返す
cmd_due() {
    require_db
    jq -r "${JQ_LIB}"'
      now as $now
      | .domains | to_entries[]
      | select($d == "" or .key == $d)
      | .key as $dom
      | (.value.items // [])[]
      | select((.last_tested | days_since($now)) >= (.level | interval))
      | [$dom, .topic, .level, .last_tested, (.last_tested | days_since($now) | tostring), (.note // "")]
      | @tsv
    ' --arg d "${1:-}" "${DB}"
}

# show [--full] [domain] — 領域一覧、または 1 領域の項目一覧
# メモ（判定根拠）は長くなって表を崩すので既定では切り詰める。--full で全文。
NOTE_MAX=40
cmd_show() {
    require_db
    local full=0 domain=""
    while (( $# )); do
        case "$1" in
            --full) full=1 ;;
            -*) die "unknown option: $1" ;;
            *) domain="$1" ;;
        esac
        shift
    done
    if [[ -z "${domain}" ]]; then
        echo "## 習熟度サマリ"
        echo
        jq -r "${JQ_LIB}"'
          now as $now
          | [.domains | to_entries[] | .value.items[]?] as $all
          | if ($all|length) == 0 then "まだ記録がありません。PR を指定するか領域名を渡して初期判定してください。"
            else
              (["レベル","項目数"] | @tsv),
              (["professional","senior","junior","beginner"][]
               | . as $l | [($l|ja), ($all | map(select(.level == $l)) | length | tostring)] | @tsv)
            end
        ' "${DB}" | column -t -s "$(printf '\t')"
        echo
        echo "## 領域ごと"
        echo
        jq -r "${JQ_LIB}"'
          now as $now
          | if (.domains | length) == 0 then "（なし）"
            else
              (["領域","種別","レベル","項目数","要復習","最終評価"] | @tsv),
              (.domains | to_entries[]
               | .key as $dom | .value as $v
               | [$dom, ($v.kind // "unknown"), ($v.level|ja),
                  (($v.items // [])|length|tostring),
                  (($v.items // []) | map(select((.last_tested | days_since($now)) >= (.level | interval))) | length | tostring),
                  ($v.assessed_at // "-")]
               | @tsv)
            end
        ' "${DB}" | column -t -s "$(printf '\t')"
    else
        jq -e --arg d "${domain}" '.domains | has($d)' "${DB}" >/dev/null \
            || die "unknown domain: ${domain}"
        echo "## ${domain}"
        echo
        jq -r "${JQ_LIB}"'
          now as $now
          | .domains[$d] as $v
          | (["項目","レベル","最終評価","経過日数","出典","メモ"] | @tsv),
            (($v.items // [])
             | sort_by(.level|rank)
             | .[]
             | [.topic, (.level|ja), .last_tested,
                (.last_tested | days_since($now) | tostring),
                (if (.source // "") == "" then "-" else .source end),
                (.note // "" | if . == "" then "-"
                 elif $full == 1 or length <= $max then .
                 else .[0:($max - 1)] + "…" end)]
             | @tsv)
        ' --arg d "${domain}" --argjson full "${full}" --argjson max "${NOTE_MAX}" \
          "${DB}" | column -t -s "$(printf '\t')"
    fi
}

# tested [YYYY-MM-DD] — その日に出題した項目を TSV で返す（既定は今日）。COB の振り返りに使う
cmd_tested() {
    require_db
    jq -r "${JQ_LIB}"'
      .domains | to_entries[]
      | .key as $dom
      | (.value.items // [])[]
      | select(.last_tested == $day)
      | [$dom, .topic, .level, (.last_judged // .level), (.note // ""), (.source // "")]
      | @tsv
    ' --arg day "${1:-$(today)}" "${DB}"
}

cmd_path() { echo "${DB}"; }

# logs-dir — 解説ログ（input_logs）の置き場を出す。無ければ作る
cmd_logs_dir() { mkdir -p "${LOGS_DIR}"; echo "${LOGS_DIR}"; }

usage() {
    cat <<'USAGE'
usage: skills-db.sh <command> [args]

  init                                             雛形から ~/.learning/skills.json を作る（冪等）
  show [--full] [domain]                           習熟度を表で出す（--full で判定根拠を全文表示）
  upsert <domain> <topic> <level> [note] [source] [kind]
                                                   1 項目を記録する（level: beginner|junior|senior|professional）
  due [domain]                                     再出題対象を TSV で返す
  tested [YYYY-MM-DD]                              その日に出題した項目を TSV で返す（既定は今日）
  path                                             DB のパスを出す
  logs-dir                                         解説ログ（input_logs）の置き場を出す

環境変数 LEARNING_HOME でデータ置き場を差し替えられる（既定 ~/.learning）。
USAGE
}

main() {
    local cmd="${1:-}"
    shift || true
    case "${cmd}" in
        init)   cmd_init "$@" ;;
        show)   cmd_show "$@" ;;
        upsert) cmd_upsert "$@" ;;
        due)    cmd_due "$@" ;;
        tested) cmd_tested "$@" ;;
        path)   cmd_path "$@" ;;
        logs-dir) cmd_logs_dir "$@" ;;
        ""|-h|--help|help) usage ;;
        *) usage >&2; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
