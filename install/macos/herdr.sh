#!/usr/bin/env bash
# chezmoi が配った自作 herdr プラグインを herdr に登録する。
# プラグイン本体はこのリポジトリが持つので install ではなく link（herdr 管理の
# チェックアウトを作らず、~/.config/herdr/plugins/<name> をそのまま参照させる）。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

# ~/.config/herdr/plugins/<name> のうち、ここに列挙したものを link する
HERDR_PLUGIN_DIR="${HERDR_PLUGIN_DIR:-${HOME}/.config/herdr/plugins}"
HERDR_PLUGINS=("hello-run")

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

main() {
    link_plugins
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
