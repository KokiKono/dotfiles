#!/usr/bin/env bash
# GPG 署名まわりのマシン側セットアップ（冪等）。
#   1. ~/.gnupg を正しいパーミッションで用意する
#   2. gpg-agent が pinentry-mac を使うようにする（GUI からのコミットで pinentry が落ちないように）
#   3. user.email に紐づく秘密鍵を探し、その fingerprint を ~/.config/git/signing.conf に書く
#      （dot_gitconfig.tmpl がこれを include する。鍵 ID はマシン固有なので public repo には置かない）
#   4. 鍵が無ければ生成する。ただしパスフレーズ入力が要るので「対話 TTY があり CI でない」ときだけ。
# gnupg / pinentry-mac 本体は Brewfile で導入する想定。
set -Eeuo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/lib.sh"

# テストから差し替えられるようにパスは環境変数で上書き可能にする。
GNUPGHOME_DIR="${GNUPGHOME:-${HOME}/.gnupg}"
SIGNING_CONF="${GIT_SIGNING_CONF:-${HOME}/.config/git/signing.conf}"

# ~/.gnupg は 700 でないと gpg が警告を出す（環境によっては拒否する）。
ensure_gnupg_home() {
    mkdir -p "${GNUPGHOME_DIR}"
    chmod 700 "${GNUPGHOME_DIR}"
}

# gpg-agent.conf に pinentry-mac とキャッシュ TTL を書く。内容が同じなら触らない。
configure_pinentry() {
    local pinentry conf desired
    if ! pinentry="$(command -v pinentry-mac)"; then
        log "pinentry-mac が見つかりません。Brewfile 導入後に再実行してください。スキップ。"
        return 0
    fi

    conf="${GNUPGHOME_DIR}/gpg-agent.conf"
    desired="$(cat <<CONF
pinentry-program ${pinentry}
default-cache-ttl 28800
max-cache-ttl 86400
CONF
)"
    if [[ -f "${conf}" ]] && [[ "$(cat "${conf}")" == "${desired}" ]]; then
        log "gpg-agent.conf は最新です: ${conf}"
        return 0
    fi

    log "gpg-agent.conf を更新します: ${conf}"
    printf '%s\n' "${desired}" > "${conf}"
    chmod 600 "${conf}"
    # 設定を反映。agent が動いていなくてもエラーで止めない。
    if has gpgconf; then
        gpgconf --reload gpg-agent || log "gpg-agent の reload に失敗しました（次回シェル起動時に反映されます）。"
    fi
}

# email に一致する秘密鍵の fingerprint を 1 つ返す。無ければ非 0。
signing_key_id() {
    local email="$1" fpr
    # 鍵が無いときの gpg は非 0 で終わる。pipefail に巻き込まれないよう握り潰す。
    fpr="$({ gpg --list-secret-keys --with-colons "${email}" 2>/dev/null || true; } \
        | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ -n "${fpr}" ]] || return 1
    printf '%s\n' "${fpr}"
}

# 鍵が無いときだけ呼ぶ。パスフレーズを pinentry で聞かれるので対話時のみ。
generate_key() {
    local name="$1" email="$2" fpr
    if [[ ! -t 0 ]] || [[ -n "${CI:-}" ]]; then
        log "署名鍵がありません。非対話実行なので生成しません（ターミナルから 'bash install/macos/gpg.sh' で作成）。スキップ。"
        return 1
    fi

    log "署名鍵がないので生成します: ${name} <${email}>（パスフレーズを聞かれます）"
    gpg --quick-generate-key "${name} <${email}>" ed25519 sign never || {
        log "鍵の生成に失敗しました。スキップ。"
        return 1
    }

    fpr="$(signing_key_id "${email}")" || {
        log "生成した鍵を見つけられませんでした。スキップ。"
        return 1
    }
    log "公開鍵を https://github.com/settings/keys に登録してください:"
    gpg --armor --export "${fpr}"
    return 0
}

# git が include する signing.conf に fingerprint を書く。同じ内容なら触らない。
write_signing_conf() {
    local fpr="$1" desired
    desired="$(printf '[user]\n\tsigningKey = %s\n' "${fpr}")"
    if [[ -f "${SIGNING_CONF}" ]] && [[ "$(cat "${SIGNING_CONF}")" == "${desired}" ]]; then
        log "signing.conf は最新です: ${SIGNING_CONF}"
        return 0
    fi
    log "signing.conf に署名鍵を書き出します: ${SIGNING_CONF}"
    mkdir -p "$(dirname "${SIGNING_CONF}")"
    printf '%s\n' "${desired}" > "${SIGNING_CONF}"
}

main() {
    if ! has gpg; then
        log "gpg が見つかりません。Brewfile 導入後に再実行してください。スキップ。"
        return 0
    fi

    ensure_gnupg_home
    configure_pinentry

    local name email fpr
    name="$(git config --get user.name 2>/dev/null || true)"
    email="$(git config --get user.email 2>/dev/null || true)"
    if [[ -z "${email}" ]]; then
        log "git の user.email が未設定です（~/.gitconfig 配置後に再実行してください）。スキップ。"
        return 0
    fi

    if ! fpr="$(signing_key_id "${email}")"; then
        generate_key "${name:-${email}}" "${email}" || return 0
        fpr="$(signing_key_id "${email}")" || return 0
    fi

    write_signing_conf "${fpr}"
    log "署名鍵: ${fpr}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
