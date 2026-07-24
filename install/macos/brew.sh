#!/usr/bin/env bash
# Homebrew の導入と Brewfile からのパッケージ一括インストール。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

install_homebrew() {
    if has brew; then
        log "Homebrew は導入済み。スキップ。"
        return 0
    fi
    log "Homebrew を導入します。"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

load_brew_env() {
    # Apple Silicon / Intel いずれの brew も PATH に載せる
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

brew_bundle() {
    log "Brewfile からパッケージを導入します。"
    brew bundle --file "${REPO_ROOT}/Brewfile"
}

main() {
    install_homebrew
    load_brew_env
    brew_bundle
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
