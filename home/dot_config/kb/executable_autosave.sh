#!/usr/bin/env bash
# kb の変更をすべてコミットして push する。launchd が 10 分ごとに呼ぶ
# （~/Library/LaunchAgents/com.kokikono.kb-autosave.plist）。
# 目的は作業のロスト防止なので、コミットの粒度やメッセージは気にしない。
# 複数の claude セッションが同じ clone に書くため、git を操作するのはこのスクリプトだけにしている。
set -Eeuo pipefail

KB_DIR="${KB_DIR:-${HOME}/git_clone/local/kb}"

autosave() {
    cd "${KB_DIR}" 2>/dev/null || return 0
    local gitdir
    gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 0

    # 手で git を操作している最中に割り込まない
    if [[ -e "${gitdir}/index.lock" || -e "${gitdir}/MERGE_HEAD" \
          || -d "${gitdir}/rebase-merge" || -d "${gitdir}/rebase-apply" ]]; then
        return 0
    fi
    [[ -n "$(git status --porcelain)" ]] || return 0

    git add -A
    # launchd からは pinentry を出せず、署名で止まるので署名しない
    git -c commit.gpgsign=false commit -qm "autosave $(date '+%F %T')"
    if git remote get-url origin >/dev/null 2>&1; then
        git push -q origin HEAD
    fi
}

main() {
    autosave
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
