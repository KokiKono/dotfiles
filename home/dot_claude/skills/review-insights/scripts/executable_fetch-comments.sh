#!/usr/bin/env bash
# PR レビューコメントを since カーソルでインクリメンタル取得し、正規化 JSONL にする。
# 取得だけを行い、cursor は進めない（state.sh commit で確定させる）。
set -euo pipefail

DATA="${REVIEW_INSIGHTS_HOME:-$HOME/.claude/review-insights}"
CONF="$DATA/config.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo=""; since_spec=""; limit=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since_spec="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    -h|--help) echo "usage: fetch-comments.sh <repo> [--since 14d|ISO] [--limit N]" >&2; exit 2 ;;
    *) repo="$1"; shift ;;
  esac
done
[ -n "$repo" ] || { echo "usage: fetch-comments.sh <repo> [--since 14d|ISO] [--limit N]" >&2; exit 2; }

slug="$(jq -er --arg r "$repo" '.repos[$r].slug' "$CONF")"
limit="${limit:-$(jq -r '.batch_limit' "$CONF")}"
overlap="$(jq -r '.cursor_overlap_minutes' "$CONF")"
since="$("$HERE/state.sh" cursor "$repo" ${since_spec:+"$since_spec"})"
run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
next_cursor_default="$(date -u -v-"${overlap}"M +%Y-%m-%dT%H:%M:%SZ)"

bot="$(jq -r '.review_bot' "$CONF")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$DATA/$repo/raw"

# claude-review bot の marker 本文を復元する共通関数。
jqlib='
def unmarker:
  if (.body // "") | test("<!-- claude-review(-schema)?-finding ") then
    ((.body | capture("-finding (?<b>[A-Za-z0-9+/=]+) -->").b | @base64d | fromjson) as $f
     | .body = "[" + ($f.severity // "?") + "] " + ($f.title // "") + "\n" + ($f.body // "")
     | .path = ($f.path // .path)
     | .line = ($f.line // .line)
     | .source = "claude-review")
  else . end;
def noise:
  ((.body // "") | test("^\\s*@(dependabot|renovate)\\b"))
  or ((.body // "") | test("Pending migrations detected"))
  or ((.body // "") | test("Expo preview is ready"))
  or ((.body // "") | test("翻訳自動修正レポート|翻訳ファイルのテストが失敗しています"))
  or ((.body // "") | test("<!-- (auto-close-issues|dependencies-pr-|projectId:)"))
  or ((.body // "") | gsub("\\s";"") | length) < 10
  or ((.body // "") | test("^\\s*(lgtm|\\+1|:\\+1:|👍|🙏|🎉|ok|okです|ありがとうございます|ありがとうございました|確認しました|承知しました|対応しました|修正しました|なるほど|了解です)[。．!！~〜\\s]*$"; "i"));
'

# 1) inline のレビューコメント
gh api --paginate --jq '.[]' \
  "repos/$slug/pulls/comments?since=$since&sort=created&direction=asc&per_page=100" \
| jq -c --arg repo "$repo" "$jqlib"'
  {repo:$repo, kind:"inline", id:("inline:" + (.id|tostring)),
   pr:(.pull_request_url|split("/")|last|tonumber),
   author:.user.login, path:.path, line:(.line // .original_line),
   url:.html_url, created_at:.created_at, updated_at:.updated_at,
   in_reply_to_id:(if .in_reply_to_id then "inline:" + (.in_reply_to_id|tostring) else null end),
   source:"human", body:.body}
  | unmarker' > "$tmp/inline.jsonl" || true

# 2) PR 全体へのコメント（issue comment のうち PR のもの）
gh api --paginate --jq '.[]' \
  "repos/$slug/issues/comments?since=$since&sort=created&direction=asc&per_page=100" \
| jq -c --arg repo "$repo" "$jqlib"'
  select(.html_url | contains("/pull/"))
  | {repo:$repo, kind:"pr_comment", id:("issue:" + (.id|tostring)),
     pr:(.issue_url|split("/")|last|tonumber),
     author:.user.login, path:null, line:null,
     url:.html_url, created_at:.created_at, updated_at:.updated_at,
     in_reply_to_id:null, source:"human", body:.body}
  | unmarker' > "$tmp/issue.jsonl" || true

# 3) 新規コメントが付いた PR に限り、review 本文と PR メタを引く（8 並列）
cat "$tmp/inline.jsonl" "$tmp/issue.jsonl" | jq -r '.pr' | sort -un > "$tmp/prs.txt"
export slug tmp since bot repo jqlib
fetch_pr() {
  local n="$1"
  gh api "repos/$slug/pulls/$n" --jq \
    '{pr:.number, pr_author:.user.login, pr_title:.title}' > "$tmp/meta_$n.json" 2>/dev/null || true
  gh api --paginate --jq '.[]' "repos/$slug/pulls/$n/reviews" 2>/dev/null \
  | jq -c --arg repo "$repo" --arg since "$since" --arg bot "$bot" --argjson pr "$n" "$jqlib"'
      select((.body // "") != "" and .submitted_at >= $since)
      | . as $r
      | {repo:$repo, kind:"review", id:("review:" + (.id|tostring)), pr:$pr,
         author:.user.login, path:null, line:null,
         url:.html_url, created_at:.submitted_at, updated_at:.submitted_at,
         in_reply_to_id:null, source:"human", body:.body} as $base
      | if ($r.body | test("claude-review(-schema)?-run ")) then
          (($r.body | capture("-run (?<b>[A-Za-z0-9+/=]+) -->").b | @base64d | fromjson).summary_findings // [])
          | to_entries
          | map($base + {id: ($base.id + "#" + (.key|tostring)),
                         path: (.value.path // null), line: (.value.line // null),
                         body: ("[" + (.value.severity // "?") + "] " + (.value.title // "") + "\n" + (.value.body // ""))})
        elif ($r.user.login == $bot) then []
        else [$base] end
      | .[]' > "$tmp/rv_$n.jsonl" 2>/dev/null || true
}
export -f fetch_pr
# PR 単位の API 呼び出しは直列だと数百秒かかるため並列化する。
# 追記の競合を避けて PR ごとに別ファイルへ書き、後でまとめる。
[ -s "$tmp/prs.txt" ] && xargs -P 8 -I{} bash -c 'fetch_pr {}' < "$tmp/prs.txt"
cat "$tmp"/meta_*.json 2>/dev/null > "$tmp/prmeta.jsonl" || : > "$tmp/prmeta.jsonl"
cat "$tmp"/rv_*.jsonl 2>/dev/null > "$tmp/review.jsonl" || : > "$tmp/review.jsonl"

# 4) bot 除外 / ノイズ除去 / 既読除外 / PR メタ付与 / 時系列ソート
seen="$("$HERE/state.sh" get "$repo" | jq -c '.seen_ids')"
excl="$(jq -c '.exclude_authors' "$CONF")"

cat "$tmp/inline.jsonl" "$tmp/issue.jsonl" "$tmp/review.jsonl" \
| jq -c --argjson seen "$seen" --argjson excl "$excl" --arg bot "$bot" \
       --slurpfile meta <(jq -s 'unique_by(.pr)' "$tmp/prmeta.jsonl") "$jqlib"'
  select((.author as $a | $excl | index($a)) == null)
  | select((.id as $i | $seen | index($i)) == null)
  | select(noise | not)
  | .source = (if .author == $bot then "claude-review" else "human" end)
  | . as $c
  | . + (($meta[0] // []) | map(select(.pr == $c.pr)) | first // {pr_author:null, pr_title:null})
  | del(.pr)
  | .pr = $c.pr
' | jq -s 'sort_by(.updated_at)' > "$tmp/all.json"

total="$(jq 'length' "$tmp/all.json")"
jq -c --argjson n "$limit" '.[0:$n][]' "$tmp/all.json" > "$DATA/$repo/pending.jsonl"
pending_n="$(wc -l < "$DATA/$repo/pending.jsonl" | tr -d ' ')"
deferred_n=$(( total - pending_n ))

# 持ち越しがあれば、その手前までしか cursor を進めない
if [ "$deferred_n" -gt 0 ]; then
  next_cursor="$(jq -r --argjson n "$limit" '.[$n].updated_at' "$tmp/all.json")"
else
  next_cursor="$next_cursor_default"
fi

jq -n --arg nc "$next_cursor" --arg rs "$run_started" \
      --slurpfile p <(jq -s 'map(.id)' "$DATA/$repo/pending.jsonl") \
      '{next_cursor:$nc, run_started:$rs, pending_ids:$p[0]}' > "$DATA/$repo/.pending_state.json"

[ "$pending_n" -gt 0 ] && cat "$DATA/$repo/pending.jsonl" >> "$DATA/$repo/raw/$(date -u +%Y-%m).jsonl"

jq -nc --arg repo "$repo" --arg since "$since" --arg nc "$next_cursor" \
       --argjson t "$total" --argjson p "$pending_n" --argjson d "$deferred_n" \
       '{repo:$repo, since:$since, fetched:$t, pending:$p, deferred:$d, next_cursor:$nc,
         pending_file:"'"$DATA/$repo/pending.jsonl"'"}'
