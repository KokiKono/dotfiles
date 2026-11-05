#!/usr/bin/env bash
# レビュー知見の取り込み（review-insights スキルの daily.sh）を毎朝走らせる launchd を登録する。
# plist は chezmoi が配る。対象リポジトリの一覧（~/.claude/review-insights/config.json）は
# 勤務先の org 名を含むので追跡しない。無ければ daily.sh が何もせずに終わる。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

RI_LABEL="com.kokikono.review-insights"
RI_PLIST="${RI_PLIST:-${HOME}/Library/LaunchAgents/${RI_LABEL}.plist}"

load_agent() {
    if [[ -n "${CI:-}" ]] || ! has launchctl; then
        log "launchd が使えない環境です。review-insights の登録をスキップ。"
        return 0
    fi
    if [[ ! -f "${RI_PLIST}" ]]; then
        log "plist が未配備です: ${RI_PLIST}。chezmoi apply 後に再実行してください。スキップ。"
        return 0
    fi
    local domain
    domain="gui/$(id -u)"
    if launchctl print "${domain}/${RI_LABEL}" >/dev/null 2>&1; then
        log "review-insights は登録済み（スキップ）"
        return 0
    fi
    launchctl bootstrap "${domain}" "${RI_PLIST}" \
        || log "review-insights の登録に失敗しました（スキップ）: ${RI_PLIST}"
}

main() {
    load_agent
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
