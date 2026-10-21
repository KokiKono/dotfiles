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

@test "herdr.sh: sourcing defines link_plugins / install_github_plugins / main without running" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F link_plugins install_github_plugins main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"link_plugins"* ]] || false
    [[ "$output" == *"install_github_plugins"* ]] || false
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

@test "herdr.sh: installs github plugins non-interactively" {
    stub_herdr "No plugins installed."
    run_script
    [ "$status" -eq 0 ]
    grep -qF "plugin install -y persiyanov/herdr-reviewr" "${LOG}"
}

@test "herdr.sh: does not install a github plugin twice" {
    stub_herdr "- persiyanov.reviewr (reviewr) enabled [github:persiyanov/herdr-reviewr@a253b1b]"
    run_script
    [ "$status" -eq 0 ]
    ! grep -qF "plugin install" "${LOG}"
    [[ "$output" == *"既に install 済み"* ]] || false
}

@test "herdr.sh: every plugin_action key binding has its plugin installed" {
    # config.toml が呼ぶ <plugin_id>.<action> のうち外部のものは、HERDR_GITHUB_PLUGINS に
    # 入っていないと新マシンでキーが空振りする。plugin_id の名前部分 (reviewr) が
    # リポジトリ名 (herdr-reviewr) に含まれることで対応を見る
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; printf '%s\n' \"\${HERDR_GITHUB_PLUGINS[@]}\""
    [ "$status" -eq 0 ]
    local repos="$output" id name
    while read -r id; do
        [[ "$id" == kokikono.* ]] && continue
        name="${id#*.}"
        [[ "$repos" == *"${name}"* ]] || false
    done < <(awk -F'"' '/^type = "plugin_action"/{p=1; next} p && /^command =/{split($2, a, "."); print a[1] "." a[2]; p=0}' \
        "${REPO_ROOT}/home/dot_config/herdr/config.toml")
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
