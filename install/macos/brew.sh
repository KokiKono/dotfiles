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

trust_taps() {
    # 新しい Homebrew（4.x 以降）は非公式 tap の formula/cask 読込に信頼を要求する。
    # 未信頼だと `brew bundle` が "Refusing to load ... from untrusted tap" で失敗するため、
    # Brewfile に書かれた非公式 tap を事前に信頼する（公式 homebrew/* は信頼済み）。
    brew help trust >/dev/null 2>&1 || return 0   # 旧 brew に trust が無ければ何もしない
    local tap
    while IFS= read -r tap; do
        case "$tap" in
            homebrew/*) continue ;;
        esac
        log "tap を信頼します: ${tap}"
        brew trust --tap "$tap" >/dev/null 2>&1 || true
    done < <(awk -F'"' '/^tap /{print $2}' "${REPO_ROOT}/Brewfile")
}

brew_bundle() {
    log "Brewfile からパッケージを導入します。"
    brew bundle --file "${REPO_ROOT}/Brewfile"
}

main() {
    install_homebrew
    load_brew_env
    trust_taps
    brew_bundle
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
