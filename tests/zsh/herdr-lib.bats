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

# --- Herdr.app（herdr-app と hc）向けの経路 ---

# space s1 / s2 を持ち、s2 にだけ dev-issue-42 という名前のタブがある app を装う。
# そのタブのターミナル t2 は /work/issue-42/repo で始まっている。呼び出しは CALLS に残る。
stub_app() {
    CALLS="${BATS_TEST_TMPDIR}/calls"
    : >"${CALLS}"
    cat >"${STUB}/herdr-app" <<EOF
#!/usr/bin/env bash
echo "herdr-app \$*" >>"${CALLS}"
case "\$1" in
  ls) echo '{"spaces":[
         {"id":"s1","active":true,"tabs":[{"id":"tb1","name":"1","terminals":[{"terminal":"t1","pane":"p1"}]}]},
         {"id":"s2","active":false,"tabs":[{"id":"tb2","name":"dev-issue-42","terminals":[{"terminal":"t2","pane":"p2"}]}]}]}' ;;
  do)
    case "\$2" in
      tab.new) echo '{"space":"s1","tab":"tb2","terminal":"t2"}' ;;
      pane.split) echo '{"pane":"p9","terminal":"t9"}' ;;
      *) echo '{"ok":true}' ;;
    esac ;;
esac
EOF
    cat >"${STUB}/hc" <<EOF
#!/usr/bin/env bash
echo "hc \$*" >>"${CALLS}"
case "\$1" in
  ls) echo '{"terminals":[{"address":"t1","cwd":"/home"},{"address":"t2","cwd":"/work/issue-42/repo"}]}' ;;
  get) echo '{"labels":{"herdr.space":"s2"},"status":{"app":"claude-code","state":"idle"}}' ;;
esac
EOF
    chmod +x "${STUB}/herdr-app" "${STUB}/hc"
}

run_app() {
    local expr="$1"; shift
    run_fn "${expr}" HC_TERMINAL_ID=t1 "$@"
}

@test "__hz_backend: app inside a Herdr.app terminal, tui when herdr runs inside it" {
    run_fn '__hz_backend' HC_TERMINAL_ID=t1
    [ "$output" = "app" ]
    # app のターミナルの中で TUI を動かすと両方が入る。内側の TUI を優先する
    run_fn '__hz_backend' HC_TERMINAL_ID=t1 HERDR_ENV=1
    [ "$output" = "tui" ]
    run_fn '__hz_backend'
    [ "$output" = "tui" ]
    run_fn '__hz_backend' HERDR_BACKEND=app
    [ "$output" = "app" ]
}

@test "__hz_workspace_id (app): reads the space label of its own terminal" {
    stub_app
    run_app '__hz_workspace_id'
    [ "$status" -eq 0 ]
    [ "$output" = "s2" ]
}

@test "__hz_find_tab (app): finds a named tab in another space" {
    stub_app
    run_app '__hz_find_tab dev-issue-42 /work/issue-42'
    [ "$status" -eq 0 ]
    [ "$output" = $'s2\ttb2' ]
    # 名前は合っていてもペインが別の場所に居るなら別物
    run_app '__hz_find_tab dev-issue-42 /other/issue-42'
    [ "$status" -ne 0 ]
}

@test "__hz_create_tab (app): names the tab, keeps focus and returns its pane" {
    stub_app
    run_app '__hz_create_tab s1 dev-issue-42 /work/issue-42'
    [ "$status" -eq 0 ]
    [ "$output" = $'tb2\tp2' ]
    grep -q -- 'do tab.new --name dev-issue-42 --space s1 --folder /work/issue-42 --focus false' "${CALLS}"
}

@test "__hz_split_pane (app): starts the new pane in the given directory" {
    # app の pane.split には cwd の引数が無い。argv で cd させないと、割ったペインの cwd になる
    stub_app
    run_app '__hz_split_pane p2 down /work/issue-42/repo'
    [ "$status" -eq 0 ]
    [ "$output" = "p9" ]
    grep -q -- 'do pane.split --direction down --pane p2 --argv' "${CALLS}"
    grep -q -- 'cd -- ' "${CALLS}"
    grep -q -- '"/work/issue-42/repo"' "${CALLS}"
}

@test "__hz_start_claude / __hz_prompt_agent (app): type into the pane's terminal" {
    stub_app
    run_app '__hz_start_claude dev-issue-42 p2 --permission-mode plan'
    [ "$status" -eq 0 ]
    grep -qx -- 'hc send t2 claude --permission-mode plan' "${CALLS}"
    run_app '__hz_prompt_agent dev-issue-42 p2 "hello there"'
    [ "$status" -eq 0 ]
    grep -qx -- 'hc send t2 hello there' "${CALLS}"
}

@test "__hz_focus_tab / __hz_close_tab (app): select the space first, close without a dialog" {
    stub_app
    run_app '__hz_focus_tab s2 tb2'
    [ "$status" -eq 0 ]
    grep -q -- 'do space.select --id s2' "${CALLS}"
    grep -q -- 'do tab.select --id tb2' "${CALLS}"
    run_app '__hz_close_tab tb2'
    grep -q -- 'do tab.close --id tb2 --confirmed true' "${CALLS}"
}
