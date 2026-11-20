#!/usr/bin/env bash
# kb.sh [<名前>]: kb/mutations のパスを出す。無ければ作る（冪等）。名前を渡すとその下のディレクトリを作って出す。
# kb の場所は ./kb（hello-run がセッションに張る symlink）→ $HELLO_RUN_KB → ~/git_clone/local/kb の順。
set -Eeuo pipefail

ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets" && pwd)"

kb_root() {
  local d
  for d in ./kb "${HELLO_RUN_KB:-}" "$HOME/git_clone/local/kb"; do
    [[ -n "$d" && -d "$d" ]] || continue
    (cd "$d" && pwd -P)
    return 0
  done
  return 1
}

main() {
  local kb name=${1:-} dir
  kb=$(kb_root) || { echo "kb.sh: kb が見つかりません（./kb, \$HELLO_RUN_KB, ~/git_clone/local/kb）" >&2; return 1; }
  # 名前はディレクトリ 1 段だけ。kb の他の場所へ書かせない
  if [[ "$name" == */* || "$name" == .* ]]; then
    echo "kb.sh: 名前に / や先頭の . は使えません: $name" >&2
    return 1
  fi
  dir="$kb/mutations"
  mkdir -p "$dir"
  [[ -e "$dir/README.md" ]] || cp "$ASSETS/README.md" "$dir/README.md"
  if [[ -n "$name" ]]; then
    dir="$dir/$name"
    mkdir -p "$dir"
  fi
  printf '%s\n' "$dir"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
