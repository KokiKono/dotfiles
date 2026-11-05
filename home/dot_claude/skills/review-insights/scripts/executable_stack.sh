#!/usr/bin/env bash
# 分類済みエントリを backlog.json に取り込み、backlog.md を再生成する。
set -euo pipefail

DATA="${REVIEW_INSIGHTS_HOME:-$HOME/.claude/review-insights}"
CONF="$DATA/config.json"

usage() {
  cat >&2 <<'USAGE'
usage:
  stack.sh apply <repo> <classified.json>   分類結果を backlog に反映し md を再生成
  stack.sh render <repo>                    backlog.md を再生成
  stack.sh list <repo> [min_count]          昇格候補を JSON で表示
  stack.sh promote <repo> <id> [status]     エントリを promoted（または rejected）にする
  stack.sh decide <repo> <decisions.json>   自動昇格の判定を backlog に反映し rules を再生成
  stack.sh rules <repo>                     個人ルール（~/.claude/rules/review-insights/auto-<repo>-*.md）を再生成
  stack.sh status <repo>                    件数サマリ

昇格候補は count が promote_min（既定 3）以上のもの。self_login の PR に付いた指摘は 1 件で候補になる。

classified.json の形（配列）:
  {"verdict":"stack"|"covered"|"noise",
   "comment_ids":["inline:123"],
   "rule":"守るべきこと 1 行",
   "target_file":".claude/rules/model.md",
   "merge_into":"b-1a2b3c4d" | null,
   "reason":"covered/noise の理由",
   "evidence":{"pr":45053,"url":"https://...","date":"2026-10-15","excerpt":"...","author":"reviewer","pr_author":"me","source":"human"}}

decisions.json の形（配列）:
  {"id":"b-1a2b3c4d", "verdict":"adopt"|"reject", "section":"データ取得", "rule":"整えたルール 1 行",
   "paths":["**/app/models/**/*.rb"], "reason":"reject の理由"}
  paths が空のルールは横断ルールとして auto-<repo>-common.md に入る（always_max 件まで）。
USAGE
  exit 2
}

cmd="${1:-}"; repo="${2:-}"
[ -n "$cmd" ] && [ -n "$repo" ] || usage
jq -e --arg r "$repo" '.repos[$r]' "$CONF" >/dev/null || { echo "unknown repo: $repo" >&2; exit 1; }
BL="$DATA/$repo/backlog.json"
[ -f "$BL" ] || echo '[]' > "$BL"
RULES="${REVIEW_INSIGHTS_RULES:-$HOME/.claude/rules/review-insights.md}"
RULES_DIR="${REVIEW_INSIGHTS_RULES_DIR:-$HOME/.claude/rules/review-insights}"
ALWAYS_MAX="$(jq -r '.always_max // 10' "$CONF")"
MIN="$(jq -r '.promote_min // 3' "$CONF")"
ME="$(jq -r '.self_login // ""' "$CONF")"
# 自分の PR への指摘は、他人の PR で 3 回見るまで待たずに拾う。初見の失敗を防ぐのが目的なので。
JQ_READY='def ready($m; $me): .status == "stacked"
  and (.count >= $m or ($me != "" and any(.occurrences[]?; .pr_author == $me)));'

render() {
  local md="$DATA/$repo/backlog.md"
  {
    echo "# レビュー知見バックログ — $repo"
    echo
    echo "最終更新: $(date '+%Y-%m-%d %H:%M')"
    echo
    jq -r --argjson m "$MIN" --arg me "$ME" "$JQ_READY"'
      def fmt:
        "### " + .rule + "\n\n"
        + "- 提案配置先: `" + (.target_file // "?") + "`\n"
        + "- 出現: " + (.count|tostring) + " 件（" + .first_seen[0:10] + " 〜 " + .last_seen[0:10] + "）\n"
        + "- 内訳: human " + ((.occurrences | map(select(.source=="human")) | length)|tostring)
          + " / claude-review " + ((.occurrences | map(select(.source=="claude-review")) | length)|tostring) + "\n"
        + "- 根拠:\n"
        + (.occurrences | sort_by(.date) | reverse | .[0:5]
           | map("  - [#" + (.pr|tostring) + "](" + .url + ") " + .date + " — " + (.excerpt | gsub("\n";" ") | .[0:100])) | join("\n"))
        + "\n";
      (map(select(ready($m; $me))) | sort_by(-.count)) as $hot
      | (map(select(.status == "stacked" and (ready($m; $me) | not))) | sort_by(-.count)) as $cold
      | (map(select(.status == "promoted")) | sort_by(.rule)) as $done
      | "## 昇格候補（" + ($m|tostring) + " 件以上、または自分の PR への指摘）\n\n" + (if ($hot|length) == 0 then "なし\n" else ($hot | map(fmt) | join("\n")) end)
      + "\n## 観測中\n\n" + (if ($cold|length) == 0 then "なし\n" else ($cold | map(fmt) | join("\n")) end)
      + "\n## 昇格済み\n\n" + (if ($done|length) == 0 then "なし\n" else ($done | map("- " + .rule + " → `" + (.target_file // "?") + "`") | join("\n") + "\n") end)
    ' "$BL"
  } > "$md"
  echo "$md"
}

# 昇格したルールを、適用範囲（paths）ごとのファイルに書き出す。paths: 付きのファイルは
# 該当するファイルを触ったときだけ読み込まれるので、ルールが増えても常に読む量は増えない。
# paths の無い横断ルールだけは常に読み込まれるので、件数の多い順に always_max 件で切る。
# 切ったものは review-check の WF が差分を見て選ぶ。
render_rules() {
  local g f name
  mkdir -p "$RULES_DIR"
  rm -f "$RULES_DIR/auto-$repo-"*.md
  jq -c --argjson max "$ALWAYS_MAX" '
    map(select(.status == "promoted" and .auto == true))
    | (map(select((.paths // []) | length > 0)) | group_by(.paths | sort)
       | map({paths: .[0].paths, rules: .})) as $scoped
    | (map(select((.paths // []) | length == 0)) | sort_by(-.count, .promoted_at) | .[0:$max]) as $common
    | ($scoped + (if ($common | length) > 0 then [{paths: [], rules: $common}] else [] end))[]' "$BL" \
  | while IFS= read -r g; do
      if [ "$(jq '.paths | length' <<<"$g")" -eq 0 ]; then
        name=common
      else
        name="$(jq -r '.paths | sort | join(",")' <<<"$g" | shasum | cut -c1-8)"
      fi
      f="$RULES_DIR/auto-$repo-$name.md"
      jq -r --arg repo "$repo" '
        (if (.paths | length) > 0
         then "---\npaths:\n" + (.paths | map("  - \"" + . + "\"") | join("\n")) + "\n---\n\n"
         else "" end)
        + "# " + $repo + " のレビューから自動で昇格したルール\n\n"
        + (.rules | group_by(.section) | map(
            "## " + (.[0].section // "その他") + "\n\n"
            + (sort_by(.promoted_at) | map("- " + (.rule_final // .rule)) | join("\n")) + "\n")
          | join("\n"))' <<<"$g" > "$f"
    done
  strip_legacy_block
}

# 以前は 1 ファイル（$RULES）のマーカーの間に書いていた。分割後に残ると二重に読まれるので消す。
strip_legacy_block() {
  local b="<!-- review-insights:auto $repo -->" e="<!-- /review-insights:auto $repo -->" tmp
  [ -f "$RULES" ] && grep -qxF "$b" "$RULES" || return 0
  tmp="$(mktemp)"
  awk -v b="$b" -v e="$e" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$RULES" \
    | cat -s > "$tmp"
  mv "$tmp" "$RULES"
}

case "$cmd" in
  apply)
    src="${3:-}"; [ -f "$src" ] || usage
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # covered / noise は dropped.jsonl に理由付きで残し、二度と再判定しない
    jq -c --arg now "$now" '.[] | select(.verdict != "stack")
      | {at:$now, verdict, comment_ids, reason, rule}' "$src" >> "$DATA/$repo/dropped.jsonl"

    # id は rule の sha1 で決める。jq にハッシュ関数が無いので外で計算する
    # （@base64 の先頭 8 文字は日本語 2 文字分しか反映されず、別のルールが衝突して勝手に merge される）。
    newsrc="$(mktemp)"
    jq -c '.[] | select(.verdict == "stack")' "$src" | while IFS= read -r line; do
      h="$(printf '%s' "$(jq -r '.rule' <<<"$line")" | shasum | cut -c1-10)"
      jq -c --arg h "b-$h" '. + {_id: $h}' <<<"$line"
    done | jq -s '.' > "$newsrc"

    tmp="$(mktemp)"
    jq --slurpfile new "$newsrc" --arg now "$now" '
      . as $bl
      | reduce $new[0][] as $n ($bl;
          ($n.merge_into // $n._id) as $id
          | if (map(.id) | index($id)) then
              map(if .id == $id then
                    .count += 1
                    | .last_seen = $now
                    | .occurrences += [$n.evidence + {comment_ids: $n.comment_ids}]
                    | .target_file = (.target_file // $n.target_file)
                  else . end)
            else
              . + [{id:$id, repo:"'"$repo"'", rule:$n.rule, target_file:$n.target_file,
                    status:"stacked", count:1, first_seen:$now, last_seen:$now,
                    occurrences:[$n.evidence + {comment_ids: $n.comment_ids}]}]
            end)
    ' "$BL" > "$tmp" && mv "$tmp" "$BL"

    render > /dev/null
    jq -nc --slurpfile s "$src" --slurpfile b "$BL" --argjson m "$MIN" --arg me "$ME" "$JQ_READY"'
      {applied: ($s[0]|length),
       stacked: ($s[0]|map(select(.verdict=="stack"))|length),
       dropped: ($s[0]|map(select(.verdict!="stack"))|length),
       backlog_total: ($b[0]|length),
       promote_ready: ($b[0]|map(select(ready($m; $me)))|length)}'
    ;;
  render) render ;;
  list)
    min="${3:-$MIN}"
    jq --argjson m "$min" --arg me "$ME" "$JQ_READY"'[.[] | select(ready($m; $me))] | sort_by(-.count)' "$BL"
    ;;
  decide)
    src="${3:-}"; [ -f "$src" ] || usage
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp)"
    # stacked でない id への判定は無視する。手で promote / reject 済みのものを cron が上書きしないように。
    jq --slurpfile d "$src" --arg now "$now" --arg rules "$RULES_DIR" '
      ($d[0] | map({key: .id, value: .}) | from_entries) as $dec
      | map(if .status == "stacked" and $dec[.id] then
              $dec[.id] as $x
              | if $x.verdict == "adopt" then
                  .status = "promoted" | .auto = true | .section = $x.section | .paths = ($x.paths // [])
                  | .rule_final = ($x.rule // .rule) | .promoted_to = $rules | .promoted_at = $now
                else
                  .status = "rejected" | .auto = true | .reject_reason = $x.reason | .promoted_at = $now
                end
            else . end)' "$BL" > "$tmp" && mv "$tmp" "$BL"
    render > /dev/null
    render_rules
    jq -c --slurpfile d "$src" '[.[] | select(.id as $i | $d[0] | map(.id) | index($i)) | {id, status}]
      | {promoted: map(select(.status=="promoted"))|length, rejected: map(select(.status=="rejected"))|length}' "$BL"
    ;;
  rules) render_rules; echo "$RULES_DIR" ;;
  promote)
    id="${3:-}"; st="${4:-promoted}"; [ -n "$id" ] || usage
    tmp="$(mktemp)"
    jq --arg id "$id" --arg st "$st" 'map(if .id == $id then .status = $st else . end)' "$BL" > "$tmp" && mv "$tmp" "$BL"
    render > /dev/null
    jq -c --arg id "$id" '.[] | select(.id == $id) | {id, status, rule, target_file}' "$BL"
    ;;
  status)
    jq --argjson m "$MIN" --arg me "$ME" "$JQ_READY"'
      {total: length,
       stacked: (map(select(.status=="stacked"))|length),
       promote_ready: (map(select(ready($m; $me)))|length),
       promoted: (map(select(.status=="promoted"))|length),
       rejected: (map(select(.status=="rejected"))|length)}' "$BL"
    ;;
  *) usage ;;
esac
