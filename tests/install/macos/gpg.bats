#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/gpg.sh"

# gpg / pinentry-mac / gpgconf / git のスタブを ${BATS_TEST_TMPDIR}/$1 に作って
# そのディレクトリを echo する。fingerprint は FPR、email は EMAIL で差し替える。
_stub_bin() {
    local dir="${BATS_TEST_TMPDIR}/$1" fpr="${2:-}"
    mkdir -p "${dir}"
    cat > "${dir}/gpg" <<STUB
#!/usr/bin/env bash
case "\$1" in
    --list-secret-keys)
        [ -n "${fpr}" ] || exit 2
        echo "sec:u:255:22:0000000000000000:1700000000:::u:::scESC::::::ed25519:::0:"
        echo "fpr:::::::::${fpr}:"
        ;;
    *) exit 0 ;;
esac
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/gpgconf"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${dir}/pinentry-mac"
    cat > "${dir}/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *user.name)  echo "KokiKono" ;;
    *user.email) echo "someone@example.com" ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "${dir}"/*
    echo "${dir}"
}

@test "gpg.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "gpg.sh: sourcing defines the setup functions / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F ensure_gnupg_home configure_pinentry signing_key_id generate_key write_signing_conf main"
    [ "$status" -eq 0 ]
    for fn in ensure_gnupg_home configure_pinentry signing_key_id generate_key write_signing_conf main; do
        [[ "$output" == *"${fn}"* ]]
    done
}

@test "gpg.sh: skips safely when gpg is absent (empty PATH)" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
}

@test "gpg.sh: is chained from the chezmoi install script" {
    grep -q 'macos/gpg.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}

@test "gpg.sh: writes gpg-agent.conf and signing.conf from an existing key" {
    FPR="ABCDEF0123456789ABCDEF0123456789ABCDEF01"
    BIN="$(_stub_bin bin "${FPR}")"
    GNUPG="${BATS_TEST_TMPDIR}/gnupg"
    CONF="${BATS_TEST_TMPDIR}/git/signing.conf"

    run env PATH="${BIN}:/usr/bin:/bin" GNUPGHOME="${GNUPG}" GIT_SIGNING_CONF="${CONF}" \
        bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]

    grep -q "pinentry-program ${BIN}/pinentry-mac" "${GNUPG}/gpg-agent.conf"
    grep -q "default-cache-ttl" "${GNUPG}/gpg-agent.conf"
    grep -q "signingKey = ${FPR}" "${CONF}"
    # ~/.gnupg は 700 であること
    [ "$(stat -f '%Lp' "${GNUPG}")" = "700" ]
}

@test "gpg.sh: is idempotent on a second run" {
    FPR="ABCDEF0123456789ABCDEF0123456789ABCDEF01"
    BIN="$(_stub_bin bin2 "${FPR}")"
    GNUPG="${BATS_TEST_TMPDIR}/gnupg2"
    CONF="${BATS_TEST_TMPDIR}/git2/signing.conf"
    env PATH="${BIN}:/usr/bin:/bin" GNUPGHOME="${GNUPG}" GIT_SIGNING_CONF="${CONF}" \
        bash "${REPO_ROOT}/${SCRIPT}"
    before="$(cat "${GNUPG}/gpg-agent.conf" "${CONF}")"

    run env PATH="${BIN}:/usr/bin:/bin" GNUPGHOME="${GNUPG}" GIT_SIGNING_CONF="${CONF}" \
        bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"最新です"* ]]
    [ "$(cat "${GNUPG}/gpg-agent.conf" "${CONF}")" = "${before}" ]
}

@test "gpg.sh: does not generate a key non-interactively (CI safe)" {
    # 鍵が無い状態のスタブ。非対話 + CI=1 なので生成に入らず、signing.conf も作らないこと。
    BIN="$(_stub_bin bin3)"
    GNUPG="${BATS_TEST_TMPDIR}/gnupg3"
    CONF="${BATS_TEST_TMPDIR}/git3/signing.conf"

    run env PATH="${BIN}:/usr/bin:/bin" GNUPGHOME="${GNUPG}" GIT_SIGNING_CONF="${CONF}" CI=1 \
        bash "${REPO_ROOT}/${SCRIPT}" < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
    [ ! -f "${CONF}" ]
}
