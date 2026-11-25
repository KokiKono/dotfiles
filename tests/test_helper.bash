# Bats 共通ヘルパー。各 .bats から `load` する。
# .chezmoiroot を目印にリポジトリのルートを探して REPO_ROOT に設定する。
_find_repo_root() {
    local dir
    dir="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
    while [[ "${dir}" != "/" ]]; do
        if [[ -f "${dir}/.chezmoiroot" ]]; then
            echo "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 1
}

REPO_ROOT="$(_find_repo_root)"
export REPO_ROOT

# Herdr.app のターミナルから流すと HC_TERMINAL_ID を引き継ぎ、herdr-lib.zsh が app 向けに
# 動いて実物の app を叩く。app 向けを試すテストは自分で付け直す。
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HERDR_BACKEND
