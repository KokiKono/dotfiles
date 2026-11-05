#!/usr/bin/env bash
# launchd から毎朝呼ばれる。レビューコメントを取り込み、昇格候補を個人ルールに自動で反映する。
# LLM に任せるのは takt の 2 本の WF（review-classify / review-promote）だけで、
# 取得・検証・backlog の更新・cursor の確定はここで行う。
set -uo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$SKILL/scripts"
DATA="${REVIEW_INSIGHTS_HOME:-$HOME/.claude/review-insights}"
CONF="$DATA/config.json"
RULES="${REVIEW_INSIGHTS_RULES:-$HOME/.claude/rules/review-insights.md}"
RULES_DIR="${REVIEW_INSIGHTS_RULES_DIR:-$HOME/.claude/rules/review-insights}"
TAKT="${REVIEW_INSIGHTS_TAKT:-$HOME/.claude/skills/takt-order/scripts/takt.sh}"
# takt の作業場所。~/.claude の下は Claude Code が保護していて step から書けないので外に置く。
# LLM に見せるのは、ここに写した入力と、ここに書かせた出力だけ。
WORK="${REVIEW_INSIGHTS_WORK:-$HOME/.cache/review-insights}"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

# takt はカレントの .takt/runtime.yaml で step ごとのモデルを決める。
# 作業ディレクトリを WORK に固定し、runtime.yaml はスキル側の版を指す。
prepare_takt_project() {
  mkdir -p "$WORK/.takt"
  ln -sfn "$SKILL/takt/runtime.yaml" "$WORK/.takt/runtime.yaml"
}

# self_login が無ければ gh から引いて config に書く。一度だけ。
ensure_self_login() {
  [ -n "$(jq -r '.self_login // ""' "$CONF")" ] && return 0
  local me tmp
  me="$(gh api user --jq .login 2>/dev/null)" || return 0
  [ -n "$me" ] || return 0
  tmp="$(mktemp)"
  jq --arg me "$me" '.self_login = $me' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
}

# takt の step は作業ディレクトリの外を読めないので、agent ファイルを写しておく。
# working tree ではなく origin の既定ブランチから取る（手元のブランチが古くても判定がずれない）。
snapshot_agent_files() {
  local repo="$1" path dst ref f
  path="$(jq -r --arg r "$repo" '.repos[$r].path' "$CONF")"
  dst="$WORK/$repo/agent-files"
  rm -rf "$dst"; mkdir -p "$dst"
  [ -d "$path/.git" ] || [ -f "$path/.git" ] || { log "$repo: clone が無い ($path)"; return 1; }
  git -C "$path" fetch -q origin 2>/dev/null || log "$repo: fetch に失敗（手元の origin で続行）"
  ref="$(git -C "$path" symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/master)"
  git -C "$path" ls-tree -r --name-only "$ref" \
    | grep -E '(^|/)(CLAUDE|AGENTS)\.md$|^\.claude/rules/.+\.md$' | grep -v node_modules \
    | while IFS= read -r f; do
        mkdir -p "$dst/$(dirname "$f")"
        git -C "$path" show "$ref:$f" > "$dst/$f"
      done
}

# 個人ルール（1 ファイル + 分割したディレクトリ）を丸ごと写す。差分と巻き戻しに使う
snapshot_rules() {
  local dst="$1"
  mkdir -p "$dst/review-insights"
  cp "$RULES" "$dst/" 2>/dev/null || true
  cp "$RULES_DIR"/*.md "$dst/review-insights/" 2>/dev/null || true
}

# 分割前に昇格したエントリには paths が無いので、分類先から後付けする（冪等）
backfill_paths() {
  local repo="$1" n
  n="$(python3 "$SCRIPTS/paths.py" backfill "$DATA/$repo/backlog.json" "$WORK/$repo/agent-files")"
  [ "$n" -gt 0 ] && { log "$repo: paths を後付け $n 件"; "$SCRIPTS/stack.sh" rules "$repo" >/dev/null; }
  return 0
}

# 分類の材料として、backlog は id / rule / target_file だけに絞って渡す（occurrences を読ませない）。
write_backlog_brief() {
  local repo="$1"
  jq '[.[] | select(.status == "stacked") | {id, rule, target_file}]' \
    "$DATA/$repo/backlog.json" > "$WORK/$repo/backlog-brief.json" 2>/dev/null \
    || echo '[]' > "$WORK/$repo/backlog-brief.json"
}

# triage の noise と classify の結果を 1 本にし、pr_author を pending から埋める。
# pr_author は自分の PR かどうかの判定に使うので、LLM に写させず元データから取る。
merge_classified() {
  local dir="$1"
  jq -n --slurpfile p <(jq -s '.' "$dir/pending.jsonl") \
        --slurpfile t "$dir/triage.json" \
        --slurpfile c <( [ -f "$dir/classified.json" ] && cat "$dir/classified.json" || echo '[]' ) '
    ($p[0] | map({key: .id, value: .pr_author}) | from_entries) as $author
    | ($t[0].noise // []) as $noise
    | ($noise | map(.id)) as $noise_ids
    | ($c[0] | map(.comment_ids -= $noise_ids) | map(select(.comment_ids | length > 0))
       | map(if .evidence then .evidence.pr_author = $author[.comment_ids[0]] else . end))
      + ($noise | map(select(.id as $i | $p[0] | map(.id) | index($i)))
         | map({verdict: "noise", comment_ids: [.id], rule: null, reason: ("triage: " + .reason)}))'
}

# pending の全 id が、ちょうど 1 回ずつ現れることを確かめる。
# 取りこぼすと次回も再判定されないまま消え、重複すると count が水増しされる。
validate_coverage() {
  local dir="$1" merged="$2"
  jq -e -n --slurpfile p <(jq -s 'map(.id)' "$dir/pending.jsonl") --slurpfile m "$merged" '
    ($m[0] | map(.comment_ids[]) ) as $got
    | ($got | sort) == ($p[0] | sort)' >/dev/null
}

validate_decisions() {
  local cand="$1" dec="$2"
  jq -e -n --slurpfile c "$cand" --slurpfile d "$dec" '
    ($d[0] | type) == "array"
    and ($d[0] | all(.verdict == "adopt" or .verdict == "reject"))
    and (($d[0] | map(.id) | sort) == ($c[0] | map(.id) | sort))' >/dev/null
}

run_takt() {
  local wf="$1" task="$2"
  (cd "$WORK" && bash "$TAKT" --pipeline --skip-git -w "$SKILL/takt/$wf.yaml" -t "$task")
}

classify_repo() {
  local repo="$1" dir="$WORK/$1" out n merged
  out="$("$SCRIPTS/fetch-comments.sh" "$repo")" || { log "$repo: 取得に失敗"; return 1; }
  n="$(jq -r '.pending' <<<"$out")"
  log "$repo: 取得 $n 件（持ち越し $(jq -r '.deferred' <<<"$out") 件）"
  if [ "$n" -eq 0 ]; then
    "$SCRIPTS/state.sh" commit "$repo" >/dev/null
    return 0
  fi

  cp "$DATA/$repo/pending.jsonl" "$dir/pending.jsonl"
  write_backlog_brief "$repo"
  rm -f "$dir/triage.json" "$dir/classified.json"
  run_takt review-classify "対象ディレクトリ: $repo/（リポジトリ $repo の PR レビューコメント $n 件）" \
    || { log "$repo: review-classify が失敗。cursor は進めない"; return 1; }
  [ -f "$dir/triage.json" ] || echo '{"noise":[]}' > "$dir/triage.json"

  merged="$dir/classified.merged.json"
  merge_classified "$dir" > "$merged"
  if ! validate_coverage "$dir" "$merged"; then
    log "$repo: 分類結果が pending の全件を 1 回ずつ網羅していない。backlog に反映せず次回に回す"
    return 1
  fi
  log "$repo: $("$SCRIPTS/stack.sh" apply "$repo" "$merged")"
  "$SCRIPTS/state.sh" commit "$repo" >/dev/null
}

promote_repo() {
  local repo="$1" dir="$WORK/$1" cand
  cand="$dir/candidates.json"
  # occurrences を全部渡すと重いので、根拠は新しい 3 件に絞る
  "$SCRIPTS/stack.sh" list "$repo" | jq --arg me "$(jq -r '.self_login // ""' "$CONF")" '
    map({id, rule, target_file, count,
         self: ($me != "" and any(.occurrences[]; .pr_author == $me)),
         excerpts: (.occurrences | sort_by(.date) | reverse | .[0:3] | map({excerpt, url}))})' > "$cand"
  [ "$(jq 'length' "$cand")" -gt 0 ] || return 0

  cat "$RULES" "$RULES_DIR"/*.md > "$dir/personal-rules.md" 2>/dev/null || true
  rm -f "$dir/decisions.json"
  run_takt review-promote "対象ディレクトリ: $repo/（リポジトリ $repo の昇格候補 $(jq 'length' "$cand") 件）" \
    || { log "$repo: review-promote が失敗"; return 1; }
  if ! validate_decisions "$cand" "$dir/decisions.json"; then
    log "$repo: decisions.json が候補と一致しない。反映しない"
    return 1
  fi
  # 適用範囲は LLM に決めさせず、分類先のルールファイルの paths: から機械的に決める
  python3 "$SCRIPTS/paths.py" enrich "$cand" "$dir/decisions.json" "$dir/agent-files" > "$dir/decisions.paths.json"
  log "$repo: 昇格 $("$SCRIPTS/stack.sh" decide "$repo" "$dir/decisions.paths.json")"
}

main() {
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
  local lock="$DATA/.lock" logf before repo
  mkdir -p "$DATA/log" "$DATA/history"
  logf="$DATA/log/$(date '+%Y-%m-%d').log"
  exec >> "$logf" 2>&1
  # 前の回が長引いているときに重ねて走らせない（同じ pending.jsonl を取り合う）
  [ -f "$CONF" ] || { log "config が無いので何もしない: $CONF"; return 0; }
  mkdir "$lock" 2>/dev/null || { log "前の回が実行中なのでスキップ"; return 0; }
  trap "rmdir '$lock'" EXIT

  log "=== daily start ==="
  prepare_takt_project
  ensure_self_login
  before="$DATA/history/$(date '+%Y%m%d-%H%M%S')"
  snapshot_rules "$before"

  for repo in $(jq -r '.repos | keys[]' "$CONF"); do
    snapshot_agent_files "$repo" || continue
    backfill_paths "$repo"
    classify_repo "$repo"
    promote_repo "$repo"
  done

  # 翌朝に差分を確かめられるよう、個人ルールの変化をログに残す。戻すときは history/ の写しを使う
  snapshot_rules "$before.after"
  if diff -rq "$before" "$before.after" >/dev/null 2>&1; then
    log "個人ルールの変更なし"
    rm -rf "$before"
  else
    log "個人ルールの差分（変更前: $before）"
    (cd "$DATA/history" && diff -ruN "$(basename "$before")" "$(basename "$before").after")
  fi
  rm -rf "$before.after"
  log "=== daily end ==="

  find "$DATA/log" -name '*.log' -mtime +60 -delete 2>/dev/null
  find "$DATA/history" -mindepth 1 -maxdepth 1 -mtime +60 -exec rm -rf {} + 2>/dev/null
  find "$WORK/.takt/runs" -mindepth 1 -maxdepth 1 -mtime +14 -exec rm -rf {} + 2>/dev/null
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
