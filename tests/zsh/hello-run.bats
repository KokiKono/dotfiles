#!/usr/bin/env bats

load ../test_helper

SRC="home/dot_config/zsh/hello-run.zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    HR="${REPO_ROOT}/${SRC}"
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
}

# workspace w1 / w2 を持ち、w2 にだけ issue-42 のタブがある herdr を装う
stub_herdr() {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")
    echo '{"result":{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}}' ;;
  "tab list")
    if [[ "$*" == *"--workspace w2"* ]]; then
      echo '{"result":{"tabs":[{"tab_id":"w2:tA","label":"issue-42"}]}}'
    else
      echo '{"result":{"tabs":[{"tab_id":"w1:tA","label":"something-else"}]}}'
    fi ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/herdr"
}

run_fn() {
    run env -u HELLO_RUN_ROOT PATH="${STUB}:${PATH}" zsh -c "source '${HR}'; $1"
}

@test "hello-run.zsh: valid zsh syntax" {
    run zsh -n "${HR}"
    [ "$status" -eq 0 ]
}

@test "__hr_find_tab: finds a tab living in another workspace" {
    # タブは作ったときの workspace に残るので、現在の workspace だけ見ると
    # 既にあるタブを見落として二重に作ってしまう
    stub_herdr
    run_fn '__hr_find_tab issue-42'
    [ "$status" -eq 0 ]
    [[ "$output" == "w2"$'\t'"w2:tA" ]] || false
}

@test "__hr_find_tab: fails when no workspace has the label" {
    stub_herdr
    run_fn '__hr_find_tab issue-999'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "hello-run: focuses the owning workspace before the tab" {
    # 別 workspace のタブには tab focus だけでは移れない
    grep -q 'herdr workspace focus "$tab_ws"' "${HR}"
    grep -q '__hr_find_tab "$label"' "${HR}"
    # 現在の workspace 固定の探索に戻っていないこと
    run grep -- 'tab list --workspace "${HERDR_WORKSPACE_ID}"' "${HR}"
    [ "$status" -ne 0 ]
}

@test "hello-run: asks about the initial prompt only when creating" {
    # 既存タブへ切り替えるだけの場面で訊くと、入力待ちで止まってフォーカスが遅れる。
    # 確認は早期 return（既存タブ）より後、新規作成の進捗表示より前にあること。
    switch_line="$(grep -n '既存のタブに切り替え' "${HR}" | head -1 | cut -d: -f1)"
    ask_line="$(grep -n 'claude に初期プロンプトを送りますか' "${HR}" | head -1 | cut -d: -f1)"
    draw_line="$(grep -n '"issue を取得" "ブランチ名を推定"' "${HR}" | head -1 | cut -d: -f1)"
    [ -n "${switch_line}" ] && [ -n "${ask_line}" ] && [ -n "${draw_line}" ]
    [ "${ask_line}" -gt "${switch_line}" ]
    [ "${ask_line}" -lt "${draw_line}" ]
}

# --- workspace id の解決 -------------------------------------------------------

# focused な workspace を持つ herdr を装う
stub_herdr_focused() {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list")
    echo '{"result":{"workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w7","focused":true}]}}' ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/herdr"
}

run_fn_env() {
    local expr="$1"; shift
    run env -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_CONTEXT_JSON PATH="${STUB}:${PATH}" \
        "$@" zsh -c "source '${HR}'; ${expr}"
}

@test "__hr_workspace_id: prefers the environment variable" {
    stub_herdr_focused
    run_fn_env '__hr_workspace_id' HERDR_WORKSPACE_ID=w3
    [ "$status" -eq 0 ]
    [ "$output" = "w3" ]
}

@test "__hr_workspace_id: falls back to the plugin context json" {
    # herdr はプラグインの pane に HERDR_WORKSPACE_ID を渡さない。空のまま
    # tab create に渡すと workspace_not_found になるので、context から拾うこと
    stub_herdr_focused
    run_fn_env '__hr_workspace_id' \
        HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w5","focused_pane_id":"w5:p2"}'
    [ "$status" -eq 0 ]
    [ "$output" = "w5" ]
}

@test "__hr_workspace_id: falls back to the focused workspace" {
    stub_herdr_focused
    run_fn_env '__hr_workspace_id'
    [ "$status" -eq 0 ]
    [ "$output" = "w7" ]
}

@test "__hr_workspace_id: fails when nothing says where we are" {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
echo '{"result":{"workspaces":[]}}'
EOF
    chmod +x "${STUB}/herdr"
    run_fn_env '__hr_workspace_id'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "hello-run: tab create uses the resolved workspace id" {
    # 生の環境変数を渡すと popup から呼ばれたときに空で落ちる
    run grep -- 'tab create --workspace "${HERDR_WORKSPACE_ID}"' "${HR}"
    [ "$status" -ne 0 ]
    grep -q 'tab create --workspace "$ws"' "${HR}"
    grep -q 'ws=$(__hr_workspace_id)' "${HR}"
}


# --- タブが本当にその issue のものか ---------------------------------------------

# w2 に issue-42 ラベルのタブが 1 つあり、そのペインの cwd を指定できる herdr を装う
stub_herdr_session() {
    local pane_cwd="$1"
    cat >"${STUB}/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w2"}]}}' ;;
  "tab list") echo '{"result":{"tabs":[{"tab_id":"w2:tA","label":"issue-42"}]}}' ;;
  "pane list") echo '{"result":{"panes":[{"tab_id":"w2:tA","cwd":"${pane_cwd}"}]}}' ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/herdr"
}

run_fn_root() {
    run env PATH="${STUB}:${PATH}" HELLO_RUN_ROOT="$2" zsh -c "source '${HR}'; $1"
}

@test "__hr_find_tab: rejects a tab whose label matches but whose panes are elsewhere" {
    # issue 番号はリポジトリ間で一意ではなく、ラベルは後から付け替えられる。
    # ラベルだけを信じると、別の issue のタブへ黙って切り替えてしまう
    stub_herdr_session "/r/.sessions/issue-99/auto_reserve"
    run_fn_root '__hr_find_tab issue-42' /r
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "__hr_find_tab: accepts a tab whose panes live in the session directory" {
    stub_herdr_session "/r/.sessions/issue-42/auto_reserve"
    run_fn_root '__hr_find_tab issue-42' /r
    [ "$status" -eq 0 ]
    [[ "$output" == "w2"$'\t'"w2:tA" ]] || false
}

@test "__hr_find_tab: accepts the session directory itself, not just below it" {
    # main ペインはセッションディレクトリそのものに居る
    stub_herdr_session "/r/.sessions/issue-42"
    run_fn_root '__hr_find_tab issue-42' /r
    [ "$status" -eq 0 ]
}

@test "__hr_find_tab: falls back to the label when the root is unknown" {
    # HELLO_RUN_ROOT が無いと検証しようがないので、従来どおりラベルだけで判断する
    stub_herdr_session "/somewhere/else"
    run_fn '__hr_find_tab issue-42'
    [ "$status" -eq 0 ]
    [[ "$output" == "w2"$'\t'"w2:tA" ]] || false
}
