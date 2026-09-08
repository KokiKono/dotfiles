#!/usr/bin/env bash
# skills-lock.json に記録された外部エージェントスキルを `npx skills add` で復元する。
# スキル本体は upstream が持つのでリポジトリには置かず、台帳（lock）だけを管理する。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

LOCK_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills-lock.json"
# 導入先エージェント。`skills add -a` に渡す。
SKILLS_AGENT="${SKILLS_AGENT:-claude-code}"
# 導入済み判定に使うディレクトリ（claude-code の場合）
SKILLS_DEST="${SKILLS_DEST:-${HOME}/.claude/skills}"

# lock から "<skill name><TAB><source repo>" を1行ずつ吐く
read_lock() {
    python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    lock = json.load(f)
for name, meta in lock.get("skills", {}).items():
    source = meta.get("source")
    if source:
        print(f"{name}\t{source}")
PY
}

install_skills() {
    if ! has npx; then
        log "npx が見つかりません。node 導入後に再実行してください。スキップ。"
        return 0
    fi
    if [[ ! -f "${LOCK_FILE}" ]]; then
        log "skills-lock.json が見つかりません: ${LOCK_FILE}。スキップ。"
        return 0
    fi
    if ! has python3; then
        log "python3 が見つかりません（lock のパースに必要）。スキップ。"
        return 0
    fi

    log "外部スキルを ${SKILLS_AGENT} 向けに復元します: ${LOCK_FILE}"
    local failed=()
    while IFS=$'\t' read -r name source; do
        [[ -z "${name}" ]] && continue
        if [[ -e "${SKILLS_DEST}/${name}" ]]; then
            log "既に導入済み（スキップ）: ${name}"
            continue
        fi
        # upstream が消えても他のスキルを止めない（graceful skip）。
        # -s は複数スキルを持つリポジトリで対象を絞るため。単体リポジトリでは
        # 名前が一致しないことがあるので、失敗したら -s なしで再試行する。
        npx -y skills@latest add "${source}" -g -s "${name}" -a "${SKILLS_AGENT}" -y \
            || npx -y skills@latest add "${source}" -g -a "${SKILLS_AGENT}" -y \
            || log "スキルの導入に失敗（スキップ）: ${name} <- ${source}"
        # skills CLI は失敗しても終了コード 0 を返すことがあるので、実体で確認する。
        # 取りこぼしはこのスクリプトを再実行すれば入る（導入済みはスキップされる）。
        if [[ ! -e "${SKILLS_DEST}/${name}" ]]; then
            log "警告: 導入されていません（再実行で入ることがあります）: ${name} <- ${source}"
            failed+=("${name}")
        fi
    done < <(read_lock "${LOCK_FILE}")

    if (( ${#failed[@]} > 0 )); then
        log "未導入 ${#failed[@]} 件: ${failed[*]}"
    fi
}

main() {
    install_skills
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
