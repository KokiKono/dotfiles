#!/usr/bin/env bash
# 指定 URL を 375/768/1440 の3幅で撮影し、$TMPDIR に w<幅>.png として保存する。
# 使い方: capture-3widths.sh <URL> [出力ディレクトリ]
#
# chrome-devtools の CLI を使う（MCP はユーザーの Chrome プロファイルを掴んで競合する）。
# CLI のブラウザは全 worktree 共有で、選択中タブが他セッションに奪われる。撮影のたびに
# タブを選び直し、実際に開いた URL と innerWidth を検算する（別ページを撮る事故が実際に起きた）。
set -euo pipefail

URL="${1:?使い方: capture-3widths.sh <URL> [出力ディレクトリ]}"
OUT="${2:-${TMPDIR:-/tmp}}"   # $TMPDIR 以外は "not within any of the configured workspace roots" で拒否される
OUT="${OUT%/}"

code=$(curl -s -o /dev/null -w "%{http_code}" "$URL" || echo 000)
if [[ "$code" != "200" ]]; then
  echo "NG: $URL が HTTP $code。dev サーバーの起動はユーザーに依頼し、200 になってから再実行する。" >&2
  exit 1
fi

# 対象タブを選び直す（他セッションに奪われている前提で毎回やる）
pages=$(chrome-devtools list_pages 2>&1) || true
idx=$(printf '%s\n' "$pages" | grep -oE '^[[:space:]]*([0-9]+)' | head -1 | tr -d ' ')
[[ -n "${idx:-}" ]] && chrome-devtools select_page "$idx" >/dev/null 2>&1 || true

for w in 375 768 1440; do
  chrome-devtools emulate --viewport "${w}x900"        # resize_page は OS 最小幅 500px に丸められるので使わない
  chrome-devtools navigate_page --url "$URL"          # reload に頼らず毎回 --url を明示する
  chrome-devtools take_screenshot --fullPage true --filePath "$OUT/w$w.png"

  check=$(chrome-devtools evaluate_script "() => [location.href, innerWidth]" 2>&1)
  printf '%s\n' "$check" | grep -q "$w" || {
    echo "NG: 幅 ${w}px の検算に失敗。開いているページか viewport が想定と違う:" >&2
    printf '%s\n' "$check" >&2
    exit 1
  }
  echo "撮影: $OUT/w$w.png  ($check)"
done

echo "3枚を $OUT に保存した。Read ツールで目視し、崩れやローディング途中でないか確認する。"
