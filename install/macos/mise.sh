#!/usr/bin/env bash
# mise のグローバル config（~/.config/mise/config.toml）に定義したツールを導入する（冪等）。
# mise 本体は Brewfile で導入する想定。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

install_mise_tools() {
    if ! has mise; then
        log "mise が見つかりません。Brewfile 導入後に再実行してください。スキップ。"
        return 0
    fi
    log "mise install でグローバル config のツールを導入します。"
    mise install
}

main() {
    install_mise_tools
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
