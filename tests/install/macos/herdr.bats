#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/herdr.sh"
PLUGIN_SRC="home/dot_config/herdr/plugins/hello-run"

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    PLUGIN_DIR="${BATS_TEST_TMPDIR}/plugins"
    mkdir -p "${STUB_DIR}" "${PLUGIN_DIR}/hello-run"
    cp "${REPO_ROOT}/${PLUGIN_SRC}/herdr-plugin.toml" "${PLUGIN_DIR}/hello-run/"
}

# herdr をスタブして、呼ばれた引数を LOG に書き出す。
# $1 に `plugin list` の出力を渡すと「登録済み」の状況を再現できる。
stub_herdr() {
    LOG="${BATS_TEST_TMPDIR}/herdr.log"
    : >"${LOG}"
    cat >"${STUB_DIR}/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${LOG}"
if [[ "\$1 \$2" == "plugin list" ]]; then
    cat <<'LIST'
$1
LIST
fi
exit 0
EOF
    chmod +x "${STUB_DIR}/herdr"
}

run_script() {
    run env PATH="${STUB_DIR}:/usr/bin:/bin" HERDR_PLUGIN_DIR="${PLUGIN_DIR}" \
        bash "${REPO_ROOT}/${SCRIPT}"
}

@test "herdr.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "herdr.sh: sourcing defines link_plugins / main without running" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F link_plugins main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"link_plugins"* ]] || false
    [[ "$output" == *"main"* ]] || false
}

@test "herdr.sh: skips safely when herdr is absent" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]] || false
}

@test "herdr.sh: links a deployed plugin" {
    stub_herdr "No plugins installed."
    run_script
    [ "$status" -eq 0 ]
    grep -qF "plugin link ${PLUGIN_DIR}/hello-run" "${LOG}"
}

@test "herdr.sh: does not link twice when already registered" {
    stub_herdr "- kokikono.hello-run (hello-run) enabled [local:${PLUGIN_DIR}/hello-run]"
    run_script
    [ "$status" -eq 0 ]
    ! grep -qF "plugin link" "${LOG}"
    [[ "$output" == *"既に link 済み"* ]] || false
}

@test "herdr.sh: skips a plugin that chezmoi has not deployed" {
    rm -rf "${PLUGIN_DIR}/hello-run"
    stub_herdr "No plugins installed."
    run_script
    [ "$status" -eq 0 ]
    ! grep -qF "plugin link" "${LOG}"
}

@test "herdr.sh: every listed plugin exists in the chezmoi source" {
    # HERDR_PLUGINS の列挙と home/ 配下の実体がずれていないこと
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; printf '%s\n' \"\${HERDR_PLUGINS[@]}\""
    [ "$status" -eq 0 ]
    while read -r name; do
        [ -f "${REPO_ROOT}/home/dot_config/herdr/plugins/${name}/herdr-plugin.toml" ]
    done <<<"$output"
}

@test "herdr.sh: is chained from the chezmoi install script" {
    grep -q 'macos/herdr.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}
