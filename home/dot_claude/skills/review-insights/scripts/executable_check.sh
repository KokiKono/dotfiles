#!/usr/bin/env bash
# 差分を、レビューから昇格した個人ルールに照らして確かめる。カレントのリポジトリで実行する。
# paths で当たるルールはここで機械的に拾い、横断ルールだけを takt の select（haiku）に選ばせ、
# review（sonnet）が差分と照合する。一般的なコードレビューはしない（/code-review の仕事）。
set -euo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$SKILL/scripts"
DATA="${REVIEW_INSIGHTS_HOME:-$HOME/.claude/review-insights}"
CONF="$DATA/config.json"
WORK="${REVIEW_INSIGHTS_WORK:-$HOME/.cache/review-insights}"
TAKT="${REVIEW_INSIGHTS_TAKT:-$HOME/.claude/skills/takt-order/scripts/takt.sh}"

usage() { echo "usage: check.sh [PR番号 | --base <ref>]" >&2; exit 2; }

# origin の URL から owner/repo を取り、config の repos を引く
repo_key() {
  local slug
  slug="$(git remote get-url origin | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
  jq -r --arg s "$slug" '.repos | to_entries[] | select(.value.slug == $s) | .key' "$CONF" | head -1
}

# 昇格済みのルールを、照合に要る項目だけに絞る
promoted_rules() {
  jq '[.[] | select(.status == "promoted")
       | {id, section, rule: (.rule_final // .rule), paths: (.paths // [])}]' "$DATA/$1/backlog.json"
}

main() {
  local pr="" base="" repo name dir
  case "${1:-}" in
    --base) base="${2:-}"; [ -n "$base" ] || usage ;;
    -h|--help) usage ;;
    "") ;;
    *) pr="${1#\#}" ;;
  esac

  repo="$(repo_key)"
  [ -n "$repo" ] || { echo "このリポジトリは config.json の repos にありません" >&2; exit 1; }
  name="${pr:+pr-$pr}"; name="${name:-$(git rev-parse --abbrev-ref HEAD | tr '/' '-')}"
  dir="$WORK/check/$repo-$name"
  rm -rf "$dir"; mkdir -p "$dir"

  if [ -n "$pr" ]; then
    gh pr diff "$pr" > "$dir/diff.patch"
    gh pr diff "$pr" --name-only > "$dir/files.txt"
    gh pr view "$pr" --json title,body --jq '"# " + .title + "\n\n" + .body' > "$dir/pr.md"
  else
    if [ -z "$base" ]; then
      base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD || echo origin/master)"
    fi
    base="$(git merge-base "$base" HEAD)"
    # PR を出す前の確認にも使うので、未コミットの変更まで含める
    git diff -U10 "$base" > "$dir/diff.patch"
    git diff --name-only "$base" > "$dir/files.txt"
    : > "$dir/pr.md"
  fi
  [ -s "$dir/files.txt" ] || { echo "差分がありません"; return 0; }

  promoted_rules "$repo" > "$dir/rules.json"
  python3 "$SCRIPTS/paths.py" match "$dir/rules.json" "$dir/files.txt" > "$dir/matched.json"
  jq -r --slurpfile m "$dir/matched.json" '
    map(select(.id as $i | $m[0] | index($i)))
    | if length == 0 then "（該当なし）" else map("- [" + .id + "] " + .rule) | join("\n") end' \
    "$dir/rules.json" > "$dir/path-rules.md"
  jq 'map(select(.paths | length == 0) | {id, section, rule})' "$dir/rules.json" > "$dir/cross-index.json"

  if [ "$(jq length "$dir/matched.json")" -eq 0 ] && [ "$(jq length "$dir/cross-index.json")" -eq 0 ]; then
    echo "照合する個人ルールがありません"
    return 0
  fi

  mkdir -p "$WORK/.takt"
  ln -sfn "$SKILL/takt/runtime.yaml" "$WORK/.takt/runtime.yaml"
  rm -f "$dir/selected.json" "$dir/findings.md"
  (cd "$WORK" && bash "$TAKT" --pipeline --skip-git -w "$SKILL/takt/review-check.yaml" \
     -t "対象ディレクトリ: check/$repo-$name/（リポジトリ $repo の差分 $(wc -l < "$dir/files.txt" | tr -d ' ') ファイル）") \
    > "$dir/takt.log" 2>&1 || { echo "review-check が失敗しました: $dir/takt.log" >&2; exit 1; }
  cat "$dir/findings.md"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
