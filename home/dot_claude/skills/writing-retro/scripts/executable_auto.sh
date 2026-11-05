#!/usr/bin/env bash
# writing-retro を無人で回す。launchd（com.kokikono.writing-retro）が毎日 19 時に呼ぶ。
#
# 候補の抜き出しまではこのスクリプトが行い、候補が無ければ claude を起動しない（トークンを使わない）。
# claude が落ちたら cursor は進まないので、翌日に同じ範囲から読み直す。
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRO_SH="${SCRIPT_DIR}/retro.sh"
RETRO_HOME="${RETRO_HOME:-${HOME}/.claude/writing-retro}"
RULES="${RETRO_RULES:-${HOME}/.claude/rules/writing.md}"
CLAUDE_BIN="${RETRO_CLAUDE:-claude}"
# 判定は候補 10 件前後の分類と 1 文の一般化なので、Opus でなくてよい
MODEL="${RETRO_MODEL:-sonnet}"
REPORT="${RETRO_HOME}/last-run.md"
LOCK="${RETRO_HOME}/.auto.lock"

log() { echo "[$(date '+%F %T')] $*"; }

notify() {
    [[ -n "${RETRO_NO_NOTIFY:-}" ]] && return 0
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "writing-retro"' \
        -e 'end run' "$1" >/dev/null 2>&1 || true
}

# 手で /writing-retro を叩いている最中や、前日の実行が残っているときは重ねない
acquire_lock() {
    mkdir -p "${RETRO_HOME}"
    if ! mkdir "${LOCK}" 2>/dev/null; then
        log "別の実行が進行中です（${LOCK}）。スキップ。"
        return 1
    fi
    trap 'rmdir "${LOCK}" 2>/dev/null || true' EXIT
}

run_claude() {
    # 許すのは retro.sh、読み取り、ルールファイルの編集だけ。それ以外のツールは -p では拒否される
    (cd "${RETRO_HOME}" && "${CLAUDE_BIN}" -p "/writing-retro auto" --model "${MODEL}" \
        --allowedTools "Bash(${RETRO_SH}:*)" "Bash(~/.claude/skills/writing-retro/scripts/retro.sh:*)" \
        "Read" "Edit(~/.claude/rules/writing.md)" "Skill(writing-retro)")
}

log_lines() {
    if [[ -f "${RETRO_HOME}/log.jsonl" ]]; then
        wc -l <"${RETRO_HOME}/log.jsonl" | tr -d ' '
    else
        echo 0
    fi
}

main() {
    acquire_lock || return 0
    local meta messages before out
    meta="$(bash "${RETRO_SH}" extract)"
    messages="$(jq -r '.messages' <<<"${meta}")"
    log "extract: $(jq -c '{since, scanned, messages}' <<<"${meta}")"
    if [[ "${messages}" == "0" ]]; then
        bash "${RETRO_SH}" commit >/dev/null
        log "候補なし。claude は起動しない。"
        return 0
    fi

    bash "${RETRO_SH}" init >/dev/null
    before="$(mktemp "${RETRO_HOME}/.rules-before.XXXXXX")"
    cp "${RULES}" "${before}"
    local log_before
    log_before="$(log_lines)"

    if ! out="$(run_claude 2>&1)"; then
        log "claude が失敗しました。cursor は進めていません。"
        printf '%s\n' "${out}"
        rm -f "${before}"
        notify "失敗しました。~/Library/Logs/writing-retro.log を確認してください"
        return 1
    fi
    printf '# %s\n\n%s\n' "$(date '+%F %T')" "${out}" >"${REPORT}"

    # 何を書いたかは claude の報告ではなく、ファイルの差分で数える
    local changed
    changed="$(diff "${before}" "${RULES}" | sed -n 's/^> - //p' || true)"
    rm -f "${before}"
    # 書いたと記録したのにファイルが変わっていなければ、Edit が失敗したまま既読にしている
    local claimed
    claimed="$(tail -n +"$((log_before + 1))" "${RETRO_HOME}/log.jsonl" 2>/dev/null \
        | jq -s '[.[] | select(.action == "added" or .action == "strengthened")] | length')"
    if [[ -z "${changed}" ]]; then
        if [[ "${claimed:-0}" -gt 0 ]]; then
            log "記録では ${claimed} 件を書いたことになっているが、ルールファイルが変わっていない。"
            notify "記録とルールファイルが食い違っています。~/.claude/writing-retro/last-run.md を確認してください"
            return 1
        fi
        log "ルールの変更なし。"
        return 0
    fi
    log "ルールを変更: $(wc -l <<<"${changed}" | tr -d ' ') 件"
    printf '%s\n' "${changed}"
    notify "ルール $(wc -l <<<"${changed}" | tr -d ' ') 件を追加・変更: $(head -1 <<<"${changed}")"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
