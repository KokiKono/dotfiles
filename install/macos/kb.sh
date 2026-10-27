#!/usr/bin/env bash
# issue をまたいで使うナレッジ置き場（kb）を用意する。
# remote は GitHub ではなくローカルの bare リポジトリ。勤務先の org にこの用途のリポジトリを
# 作った前例が無いため。中身は業務知識なので PUBLIC なこのリポジトリには置かず、初期化に使う
# 雛形（kb-seed/）だけを持つ。雛形は空のときに一度だけ置き、その後は kb 側で育てる。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kb-seed"
KB_DIR="${KB_DIR:-${HOME}/git_clone/local/kb}"
KB_REMOTE="${KB_REMOTE:-${HOME}/git_remote/kb.git}"
KB_LABEL="com.kokikono.kb-autosave"
KB_PLIST="${KB_PLIST:-${HOME}/Library/LaunchAgents/${KB_LABEL}.plist}"

init_remote() {
    if [[ -d "${KB_REMOTE}" ]]; then
        log "kb の remote は作成済み（スキップ）: ${KB_REMOTE}"
        return 0
    fi
    mkdir -p "$(dirname "${KB_REMOTE}")"
    git init -q --bare "${KB_REMOTE}"
    git -C "${KB_REMOTE}" symbolic-ref HEAD refs/heads/main
    log "kb の remote を作成しました: ${KB_REMOTE}"
}

init_clone() {
    if [[ -d "${KB_DIR}/.git" ]]; then
        log "kb は clone 済み（スキップ）: ${KB_DIR}"
        return 0
    fi
    mkdir -p "$(dirname "${KB_DIR}")"
    git clone -q "${KB_REMOTE}" "${KB_DIR}" 2>/dev/null
    # 空の remote を clone すると HEAD が init.defaultBranch（master のことがある）を指す
    git -C "${KB_DIR}" symbolic-ref HEAD refs/heads/main
    log "kb を clone しました: ${KB_DIR}"
}

seed() {
    [[ -e "${KB_DIR}/CLAUDE.md" ]] || cp "${SEED_DIR}/CLAUDE.md" "${KB_DIR}/CLAUDE.md"
    [[ -e "${KB_DIR}/.gitignore" ]] || cp "${SEED_DIR}/gitignore" "${KB_DIR}/.gitignore"
    mkdir -p "${KB_DIR}/issues"
    [[ -n "$(ls -A "${KB_DIR}/issues")" ]] || touch "${KB_DIR}/issues/.gitkeep"

    git -C "${KB_DIR}" add -A
    git -C "${KB_DIR}" diff --cached --quiet && return 0
    # user.name / email が未設定のマシンでもチェーン全体は止めない
    if ! git -C "${KB_DIR}" -c commit.gpgsign=false commit -qm "kb を初期化"; then
        log "kb の初期コミットに失敗しました（git の user.name / email を確認）。スキップ。"
        return 0
    fi
    git -C "${KB_DIR}" push -q -u origin main
}

# 10 分ごとの autosave を launchd に登録する。plist は chezmoi が配る。
load_agent() {
    if [[ -n "${CI:-}" ]] || ! has launchctl; then
        log "launchd が使えない環境です。autosave の登録をスキップ。"
        return 0
    fi
    if [[ ! -f "${KB_PLIST}" ]]; then
        log "plist が未配備です: ${KB_PLIST}。chezmoi apply 後に再実行してください。スキップ。"
        return 0
    fi
    local domain
    domain="gui/$(id -u)"
    if launchctl print "${domain}/${KB_LABEL}" >/dev/null 2>&1; then
        log "autosave は登録済み（スキップ）"
        return 0
    fi
    launchctl bootstrap "${domain}" "${KB_PLIST}" \
        || log "autosave の登録に失敗しました（スキップ）: ${KB_PLIST}"
}

main() {
    if ! has git; then
        log "git が見つかりません。スキップ。"
        return 0
    fi
    init_remote
    init_clone
    seed
    load_agent
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
