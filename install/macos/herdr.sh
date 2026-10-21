#!/usr/bin/env bash
# herdr プラグインを登録する。
# 自作のものは本体をこのリポジトリが持つので install ではなく link（herdr 管理の
# チェックアウトを作らず、~/.config/herdr/plugins/<name> をそのまま参照させる）。
# 外部のものは本体を vendoring せず、一覧だけ持って GitHub から install する。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

# ~/.config/herdr/plugins/<name> のうち、ここに列挙したものを link する
HERDR_PLUGIN_DIR="${HERDR_PLUGIN_DIR:-${HOME}/.config/herdr/plugins}"
HERDR_PLUGINS=("hello-run" "git-diff")

# GitHub から install する外部プラグイン（<owner>/<repo>）。
# config.toml のキーバインドがこれらのアクションを呼ぶので、入っていないとキーが空振りする。
HERDR_GITHUB_PLUGINS=("persiyanov/herdr-reviewr")

link_plugins() {
    if ! has herdr; then
        log "herdr が見つかりません。スキップ。"
        return 0
    fi

    # 登録済み一覧。link 済みのものを二重に登録しない判定に使う。
    local listed
    listed="$(herdr plugin list 2>/dev/null || true)"

    local name dir
    for name in "${HERDR_PLUGINS[@]}"; do
        dir="${HERDR_PLUGIN_DIR}/${name}"
        if [[ ! -f "${dir}/herdr-plugin.toml" ]]; then
            log "マニフェストが無いのでスキップ（chezmoi apply 済みか確認）: ${dir}"
            continue
        fi
        if grep -qF "local:${dir}" <<<"${listed}"; then
            log "既に link 済み（スキップ）: ${name}"
            continue
        fi
        log "herdr プラグインを link します: ${name}"
        # 1 つ失敗しても残りを止めない
        herdr plugin link "${dir}" >/dev/null || log "link に失敗（スキップ）: ${name}"
    done
}

install_github_plugins() {
    if ! has herdr; then
        log "herdr が見つかりません。スキップ。"
        return 0
    fi

    local listed
    listed="$(herdr plugin list 2>/dev/null || true)"

    local repo
    for repo in "${HERDR_GITHUB_PLUGINS[@]}"; do
        # 一覧には [github:<owner>/<repo>@<commit>] の形で出る
        if grep -qF "github:${repo}@" <<<"${listed}"; then
            log "既に install 済み（スキップ）: ${repo}"
            continue
        fi
        log "herdr プラグインを install します: ${repo}"
        # chezmoi apply 経由では確認に応答できないので -y で飛ばす。1 つ失敗しても残りを止めない
        herdr plugin install -y "${repo}" >/dev/null || log "install に失敗（スキップ）: ${repo}"
    done
}

main() {
    link_plugins
    install_github_plugins
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
