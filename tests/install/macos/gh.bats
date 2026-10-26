#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/gh.sh"

@test "gh.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "gh.sh: sourcing defines install_extensions / installed_extensions / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_extensions installed_extensions main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_extensions"* ]] || false
    [[ "$output" == *"installed_extensions"* ]] || false
    [[ "$output" == *"main"* ]] || false
}

@test "gh.sh: extension list exists and holds owner/repo pairs" {
    LIST="${REPO_ROOT}/install/macos/gh-extensions.txt"
    [ -f "${LIST}" ]
    run grep -vE '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$' "${LIST}"
    [ "$status" -ne 0 ]
}

@test "gh.sh: the gh-attach extension is no longer restored" {
    # 添付は gh 標準の --attach に移した。拡張を戻すとスキルが旧経路（リリース/ブラウザ）に流れうる
    run grep -q 'gh-attach' "${REPO_ROOT}/install/macos/gh-extensions.txt"
    [ "$status" -ne 0 ]
}

@test "gh.sh: skips safely when gh is absent" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]] || false
}

@test "gh.sh: skips safely when gh is unauthenticated" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    # auth status を失敗させる。install が呼ばれたら分かるよう痕跡を残す。
    cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 1 ;;
  extension)
    [[ "$2" == "install" ]] && touch "${STUB_MARKER}"
    exit 0 ;;
esac
exit 0
STUBEOF
    chmod +x "${STUB}/gh"
    run env PATH="${STUB}:/usr/bin:/bin" HOME="${HOME}" \
        STUB_MARKER="${BATS_TEST_TMPDIR}/installed" \
        bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"未認証"* ]] || false
    [ ! -f "${BATS_TEST_TMPDIR}/installed" ]
}

@test "gh.sh: installs only the extensions that are missing" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    cat > "${STUB}/gh" <<'STUBEOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  extension)
    case "$2" in
      list)    printf 'gh dash\tdlvhdr/gh-dash\tabc1234\n' ;;
      install) printf '%s\n' "$3" >> "${STUB_MARKER}" ;;
    esac
    exit 0 ;;
esac
exit 0
STUBEOF
    chmod +x "${STUB}/gh"
    MARKER="${BATS_TEST_TMPDIR}/installed"
    run env PATH="${STUB}:/usr/bin:/bin" HOME="${HOME}" STUB_MARKER="${MARKER}" \
        bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q 'github/gh-stack' "${MARKER}"
    run grep -q 'dlvhdr/gh-dash' "${MARKER}"
    [ "$status" -ne 0 ]
}
