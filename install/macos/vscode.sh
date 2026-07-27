#!/usr/bin/env bash
# vscode-extensions.txt に列挙された拡張を code CLI で導入する。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

EXTENSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vscode-extensions.txt"

install_extensions() {
    if ! has code; then
        log "code CLI が見つかりません。VS Code 導入後に再実行してください。スキップ。"
        return 0
    fi
    if [[ ! -f "${EXTENSIONS_FILE}" ]]; then
        log "拡張リストが見つかりません: ${EXTENSIONS_FILE}。スキップ。"
        return 0
    fi
    log "VS Code 拡張を導入します。"
    while IFS= read -r ext; do
        [[ -z "${ext}" ]] && continue
        code --install-extension "${ext}" --force
    done < "${EXTENSIONS_FILE}"
}

main() {
    install_extensions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
