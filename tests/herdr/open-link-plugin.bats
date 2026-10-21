#!/usr/bin/env bats

load ../test_helper

PLUGIN="home/dot_config/herdr/plugins/open-link"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    OPEN="${REPO_ROOT}/${PLUGIN}/executable_open.zsh"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls.log"
    mkdir -p "${STUB_DIR}"
    : >"${LOG}"
    unset HERDR_PANE_ID HERDR_TAB_ID HERDR_PLUGIN_CONTEXT_JSON HERDR_PLUGIN_CLICKED_URL
}

# terminal-browser をスタブして、受け取った引数と HERDR_PANE_ID / HERDR_TAB_ID を LOG に残す。
# $1 に new-tab の終了コードを渡すと「ブラウザが複数あって new-tab が失敗する」を再現できる。
stub_tb() {
    cat >"${STUB_DIR}/terminal-browser" <<STUB
#!/usr/bin/env bash
echo "\$* pane=\${HERDR_PANE_ID:-} tab=\${HERDR_TAB_ID:-}" >>"${LOG}"
[[ "\$1" == new-tab ]] && exit ${1:-0}
exit 0
STUB
    chmod +x "${STUB_DIR}/terminal-browser"
}

@test "open.zsh: valid zsh syntax" {
    run zsh -n "${OPEN}"
    [ "$status" -eq 0 ]
}

@test "open.zsh: opens the clicked url as a new tab" {
    stub_tb
    HERDR_PLUGIN_CLICKED_URL=https://example.com PATH="${STUB_DIR}:${PATH}" run zsh "${OPEN}"
    [ "$status" -eq 0 ]
    [ "$(cat "${LOG}")" = "new-tab https://example.com pane= tab=" ]
}

@test "open.zsh: targets the clicked pane from the plugin context" {
    # action はペインの外で走るので、どのタブのブラウザに足すかは context JSON から決める
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_tb
    HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_id":"w1:p2","tab_id":"w1:t3"}' \
        PATH="${STUB_DIR}:${PATH}" run zsh "${OPEN}" https://example.com
    [ "$status" -eq 0 ]
    [ "$(cat "${LOG}")" = "new-tab https://example.com pane=w1:p2 tab=w1:t3" ]
}

@test "open.zsh: falls back to a new split when new-tab fails" {
    stub_tb 1
    PATH="${STUB_DIR}:${PATH}" run zsh "${OPEN}" https://example.com
    [ "$status" -eq 0 ]
    [ "$(sed -n 2p "${LOG}")" = "open https://example.com --split right pane= tab=" ]
}

@test "open.zsh: uses the system browser when terminal-browser is missing" {
    # クリックを無かったことにしない
    cat >"${STUB_DIR}/open" <<STUB
#!/usr/bin/env bash
echo "open \$*" >>"${LOG}"
STUB
    chmod +x "${STUB_DIR}/open"
    PATH="${STUB_DIR}:/usr/bin:/bin" run /bin/zsh "${OPEN}" https://example.com
    [ "$status" -eq 0 ]
    [ "$(cat "${LOG}")" = "open https://example.com" ]
}

@test "open.zsh: fails without a url" {
    run zsh "${OPEN}"
    [ "$status" -ne 0 ]
}
