#!/usr/bin/env bash
# takt.sh [--root | takt の引数...]
# takt を呼ぶ。--root は takt パッケージのディレクトリ（builtins/ の親）を出す。
set -Eeuo pipefail

TAKT_NODE_INSTALLS="${TAKT_NODE_INSTALLS:-$HOME/.local/share/mise/installs/node}"

# takt が入っている node のうち一番新しいもの。mise の shim は cwd で node が決まらないと
# 落ちるので、shim に頼らずインストール先を直接探す。
pkg_dir() {
  local d
  d=$(printf '%s\n' "$TAKT_NODE_INSTALLS"/*/lib/node_modules/takt | sort -V | tail -1)
  [[ -d "$d" ]] && printf '%s\n' "$d"
}

main() {
  local pkg ver
  if [[ "${1:-}" == "--root" ]]; then
    pkg=$(pkg_dir) || { echo "takt.sh: takt が見つかりません ($TAKT_NODE_INSTALLS)" >&2; return 1; }
    printf '%s\n' "$pkg"
    return 0
  fi
  if command -v takt >/dev/null 2>&1 && takt --version >/dev/null 2>&1; then
    exec takt "$@"
  fi
  pkg=$(pkg_dir) || { echo "takt.sh: takt が見つかりません ($TAKT_NODE_INSTALLS)" >&2; return 1; }
  ver=$(basename "$(dirname "$(dirname "$(dirname "$pkg")")")")
  exec mise exec "node@$ver" -- takt "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
