#!/usr/bin/env bash
# oh-my-zsh を非対話で導入する（既存ならスキップ）。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

install_ohmyzsh() {
    if [[ -d "${HOME}/.oh-my-zsh" ]]; then
        log "oh-my-zsh は導入済み。スキップ。"
        return 0
    fi
    log "oh-my-zsh を導入します。"
    # RUNZSH=no: 導入後にサブシェルへ切り替えない / KEEP_ZSHRC=yes: 既存 .zshrc を残す
    RUNZSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
}

main() {
    install_ohmyzsh
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
