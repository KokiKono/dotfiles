#!/usr/bin/env bash
# gh-extensions.txt に列挙した gh 拡張を導入する。
# 拡張本体は upstream が持つのでリポジトリには置かず、一覧だけを管理する（skills.sh と同じ方針）。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

EXTENSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-extensions.txt"

# 導入済み拡張を "<owner>/<repo>" で1行ずつ吐く。
# `gh extension list` は "gh dash<TAB>dlvhdr/gh-dash<TAB><sha>" の形で、2 列目がリポジトリ。
installed_extensions() {
    gh extension list 2>/dev/null | cut -f2 || true
}

install_extensions() {
    if ! has gh; then
        log "gh が見つかりません。brew 導入後に再実行してください。スキップ。"
        return 0
    fi
    if [[ ! -f "${EXTENSIONS_FILE}" ]]; then
        log "拡張リストが見つかりません: ${EXTENSIONS_FILE}。スキップ。"
        return 0
    fi

    # 未認証だと install が対話を求めて固まるので、先に弾く。
    if ! gh auth status >/dev/null 2>&1; then
        log "gh が未認証です。gh auth login 後に再実行してください。スキップ。"
        return 0
    fi

    # NOTE: gh-attach はローカル修正を当てて使っている。ここでは素のまま入れるだけで、
    #       修正は pr-screenshot スキルの ensure-gh-attach-patch.sh が冪等に当て直す。
    log "gh 拡張を導入します。"
    local current
    current="$(installed_extensions)"
    while IFS= read -r ext; do
        ext="${ext%%#*}"
        ext="${ext//[[:space:]]/}"
        [[ -z "${ext}" ]] && continue
        if grep -qxF "${ext}" <<<"${current}"; then
            log "既に導入済み（スキップ）: ${ext}"
            continue
        fi
        # 1 拡張が消える/リネームされても全体を止めない（graceful skip）。
        gh extension install "${ext}" \
            || log "拡張の導入に失敗（スキップ）: ${ext}"
    done < "${EXTENSIONS_FILE}"
}

main() {
    install_extensions
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
