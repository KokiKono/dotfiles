#!/usr/bin/env bash
# nodenv-yarn-install プラグインを導入する（冪等）。nodenv 本体は Brewfile で導入する想定。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

install_yarn_plugin() {
    if ! has nodenv; then
        log "nodenv が見つかりません。Brewfile 導入後に再実行してください。スキップ。"
        return 0
    fi
    local plugin_dir
    plugin_dir="$(nodenv root)/plugins/nodenv-yarn-install"
    if [[ -d "${plugin_dir}" ]]; then
        log "nodenv-yarn-install は導入済み。スキップ。"
        return 0
    fi
    log "nodenv-yarn-install プラグインを導入します。"
    mkdir -p "$(nodenv root)/plugins"
    git clone https://github.com/pine/nodenv-yarn-install.git "${plugin_dir}"
}

main() {
    install_yarn_plugin
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
