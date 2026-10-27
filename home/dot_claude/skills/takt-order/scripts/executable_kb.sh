#!/usr/bin/env bash
# kb.sh: kb/takt のパスを出す。無ければ雛形から作る（冪等）。
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

init() {
  local tk=$1 d
  for d in workflows orders facets/knowledge facets/policies facets/instructions \
           facets/personas facets/output-contracts; do
    mkdir -p "$tk/$d"
    # git は空のディレクトリを持たないので、autosave の push 先でも構成が見えるようにする
    [[ -n "$(ls -A "$tk/$d")" ]] || : >"$tk/$d/.gitkeep"
  done
  [[ -e "$tk/README.md" ]] || cp "$ASSETS/README.md" "$tk/README.md"
  [[ -e "$tk/playbook.md" ]] || cp "$ASSETS/playbook.md" "$tk/playbook.md"
}

main() {
  local kb
  kb=$(kb_root) || { echo "kb.sh: kb が見つかりません（./kb, \$HELLO_RUN_KB, ~/git_clone/local/kb）" >&2; return 1; }
  init "$kb/takt"
  printf '%s\n' "$kb/takt"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
