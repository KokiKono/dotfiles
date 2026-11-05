#!/usr/bin/env bash
# writing-retro（文章への指摘をルールに書き戻すスキル）の自動実行を launchd に登録する。
# plist も auto.sh も chezmoi が配るので、ここでは登録だけを行う。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

RETRO_LABEL="com.kokikono.writing-retro"
RETRO_PLIST="${RETRO_PLIST:-${HOME}/Library/LaunchAgents/${RETRO_LABEL}.plist}"

load_agent() {
    if [[ -n "${CI:-}" ]] || ! has launchctl; then
        log "launchd が使えない環境です。writing-retro の登録をスキップ。"
        return 0
    fi
    if [[ ! -f "${RETRO_PLIST}" ]]; then
        log "plist が未配備です: ${RETRO_PLIST}。chezmoi apply 後に再実行してください。スキップ。"
        return 0
    fi
    local domain
    domain="gui/$(id -u)"
    if launchctl print "${domain}/${RETRO_LABEL}" >/dev/null 2>&1; then
        log "writing-retro は登録済み（スキップ）"
        return 0
    fi
    launchctl bootstrap "${domain}" "${RETRO_PLIST}" \
        || log "writing-retro の登録に失敗しました（スキップ）: ${RETRO_PLIST}"
}

main() {
    if ! has claude; then
        log "claude が見つかりません。スキップ。"
        return 0
    fi
    load_agent
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
