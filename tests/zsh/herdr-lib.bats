#!/usr/bin/env bats

load ../test_helper

SRC="home/dot_config/zsh/herdr-lib.zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    LIB="${REPO_ROOT}/${SRC}"
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
}

run_fn() {
    local expr="$1"; shift
    run env -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_CONTEXT_JSON PATH="${STUB}:${PATH}" \
        "$@" zsh -c "source '${LIB}'; ${expr}"
}

# workspace w1 / w2 を持ち、w2 にだけ dev-issue-42 のタブがある herdr を装う。
# そのタブのペインは /work/issue-42 配下に居る。
stub_herdr() {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")
    echo '{"result":{"workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true}]}}' ;;
  "tab list")
    if [[ "$*" == *"--workspace w2"* ]]; then
      echo '{"result":{"tabs":[{"tab_id":"w2:tA","label":"dev-issue-42"}]}}'
    else
      echo '{"result":{"tabs":[{"tab_id":"w1:tA","label":"dev-issue-99"}]}}'
    fi ;;
  "pane list")
    echo '{"result":{"panes":[{"pane_id":"w2:p1","tab_id":"w2:tA","cwd":"/work/issue-42/repo"}]}}' ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/herdr"
}

@test "herdr-lib.zsh: valid zsh syntax" {
    run zsh -n "${LIB}"
    [ "$status" -eq 0 ]
}

@test "__hz_find_tab: finds a tab living in another workspace" {
    # タブは作ったときの workspace に残るので、現在の workspace だけ見ると
    # 既にあるタブを見落として二重に作ってしまう
    stub_herdr
    run_fn '__hz_find_tab dev-issue-42'
    [ "$status" -eq 0 ]
    [[ "$output" == "w2"$'\t'"w2:tA" ]] || false
}

@test "__hz_find_tab: rejects a label match whose panes live elsewhere" {
    stub_herdr
    run_fn '__hz_find_tab dev-issue-42 /other/issue-42'
    [ "$status" -ne 0 ]
}

@test "__hz_find_tab: accepts a label match whose panes live under the dir" {
    stub_herdr
    run_fn '__hz_find_tab dev-issue-42 /work/issue-42'
    [ "$status" -eq 0 ]
    [[ "$output" == "w2"$'\t'"w2:tA" ]] || false
}

@test "__hz_find_tab: fails when no workspace has the label" {
    stub_herdr
    run_fn '__hz_find_tab dev-issue-999'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "__hz_find_tab: never pins the lookup to the current workspace" {
    run grep -- 'tab list --workspace "${HERDR_WORKSPACE_ID}"' "${LIB}"
    [ "$status" -ne 0 ]
}

@test "__hz_workspace_id: prefers the environment variable" {
    stub_herdr
    run_fn '__hz_workspace_id' HERDR_WORKSPACE_ID=w3
    [ "$status" -eq 0 ]
    [ "$output" = "w3" ]
}

@test "__hz_workspace_id: falls back to the plugin context json" {
    # herdr はプラグインの pane に HERDR_WORKSPACE_ID を渡さない
    stub_herdr
    run_fn '__hz_workspace_id' HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w5"}'
    [ "$status" -eq 0 ]
    [ "$output" = "w5" ]
}

@test "__hz_workspace_id: falls back to the focused workspace" {
    stub_herdr
    run_fn '__hz_workspace_id'
    [ "$status" -eq 0 ]
    [ "$output" = "w2" ]
}
