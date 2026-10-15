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

# --- 初期プロンプトのテンプレート -----------------------------------------------

render() {
    run env PATH="${STUB}:${PATH}" HELLO_RUN_PROMPT_FILE="$1" zsh -c \
        "source '${HR}'; __hr_render_prompt \
           'https://github.com/o/r/issues/42' 'o/r' 42 'ある題' 'wip/foo' 'repo_a repo_b' '/s/issue-42'"
}

@test "__hr_render_prompt: fills every placeholder from the template" {
    cat >"${BATS_TEST_TMPDIR}/p.md" <<'EOF'
{{issue_url}} / {{issue_repo}} / {{issue_number}} / {{issue_title}} / {{branch}} / {{repos}} / {{session_dir}}
EOF
    render "${BATS_TEST_TMPDIR}/p.md"
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/o/r/issues/42 / o/r / 42 / ある題 / wip/foo / repo_a repo_b / /s/issue-42" ]
}

@test "__hr_render_prompt: drops html comment lines and folds newlines" {
    # テンプレートに人間向けの注意書きを置けること、改行が送信前に畳まれること。
    # 改行をそのまま送ると claude の入力欄で途中送信になりうる
    cat >"${BATS_TEST_TMPDIR}/p.md" <<'EOF'
<!-- 送られない注意書き
     複数行にまたがる -->

一行目。

二行目。
EOF
    render "${BATS_TEST_TMPDIR}/p.md"
    [ "$status" -eq 0 ]
    [ "$output" = "一行目。 二行目。" ]
}

@test "__hr_render_prompt: falls back to the built-in text without a template" {
    # 新しいマシンで chezmoi apply より先に叩いても動くこと
    render "${BATS_TEST_TMPDIR}/missing.md"
    [ "$status" -eq 0 ]
    [[ "$output" == "https://github.com/o/r/issues/42 に取り組みます。"* ]] || false
    [[ "$output" == *"repo_a repo_b"* ]] || false
}

@test "__hr_render_prompt: falls back when the template has only comments" {
    cat >"${BATS_TEST_TMPDIR}/p.md" <<'EOF'
<!-- 本文が無い -->
EOF
    render "${BATS_TEST_TMPDIR}/p.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"まず issue の内容を確認してください。" ]] || false
}

@test "hello-run: sends the rendered prompt, not an inline literal" {
    # 文面を直接書き戻すと、テンプレートを直しても反映されなくなる
    grep -q '__hr_render_prompt "https://github.com/\$repo/issues/\$num"' "${HR}"
    run grep -c 'local text="https://github.com' "${HR}"
    [ "$output" = "0" ]
}

# --- scratch（issue 起票なしの作業）---------------------------------------------

render_scratch() {
    run env PATH="${STUB}:${PATH}" HELLO_RUN_SCRATCH_PROMPT_FILE="$1" zsh -c \
        "source '${HR}'; __hr_render_scratch_prompt \
           'ログイン後のリダイレクトを直す' 'scratch/fix-login' 'repo_a repo_b' \
           '/s/scratch-fix-login' '/s/scratch-fix-login/README.md'"
}

@test "__hr_render_scratch_prompt: fills every placeholder from the template" {
    cat >"${BATS_TEST_TMPDIR}/ps.md" <<'EOF'
{{task}} / {{branch}} / {{repos}} / {{session_dir}} / {{readme}}
EOF
    render_scratch "${BATS_TEST_TMPDIR}/ps.md"
    [ "$status" -eq 0 ]
    [ "$output" = "ログイン後のリダイレクトを直す / scratch/fix-login / repo_a repo_b / /s/scratch-fix-login / /s/scratch-fix-login/README.md" ]
}

@test "__hr_render_scratch_prompt: falls back to the built-in text without a template" {
    # 新しいマシンで chezmoi apply より先に叩いても動くこと
    render_scratch "${BATS_TEST_TMPDIR}/missing.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"README.md"* ]] || false
    [[ "$output" == *"repo_a repo_b"* ]] || false
    [[ "$output" == *"scratch/fix-login"* ]] || false
}

@test "__hr_render_scratch_prompt: uses its own template, not the issue one" {
    # 共用すると issue 用の差し込みが空のまま送られる
    cat >"${BATS_TEST_TMPDIR}/issue.md" <<'EOF'
issue 用の文面
EOF
    run env PATH="${STUB}:${PATH}" HELLO_RUN_PROMPT_FILE="${BATS_TEST_TMPDIR}/issue.md" \
        HELLO_RUN_SCRATCH_PROMPT_FILE="${BATS_TEST_TMPDIR}/missing.md" zsh -c \
        "source '${HR}'; __hr_render_scratch_prompt t b r s m"
    [ "$status" -eq 0 ]
    [[ "$output" != *"issue 用の文面"* ]] || false
}

# やりたいことを書く代わりに決め打ちの本文を流し込む EDITOR
stub_editor() {
    cat >"${STUB}/fake-editor" <<EOF
#!/usr/bin/env bash
cat >>"\$1" <<'BODY'
$1
BODY
EOF
    chmod +x "${STUB}/fake-editor"
}

read_task() {
    run env PATH="${STUB}:${PATH}" EDITOR="${STUB}/fake-editor" zsh -c \
        "source '${HR}'; __hr_read_task '${BATS_TEST_TMPDIR}/task.md'"
}

@test "__hr_read_task: keeps what was written and drops the html comment" {
    # 書いたものがそのまま README.md になるので、雛形の注意書きは残らないこと。
    # 複数行を畳まないこと（README であってプロンプトではない）
    stub_editor "$(printf 'ログインを直す\n\n- 再現手順を書く')"
    read_task
    [ "$status" -eq 0 ]
    [[ "$output" != *"やりたいこと"* ]] || false
    [[ "$output" == "ログインを直す"$'\n\n'"- 再現手順を書く" ]] || false
}

@test "__hr_read_task: fails when nothing was written" {
    # 空のまま閉じたら中止（slug も置き場も決められない）
    stub_editor ""
    read_task
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "__hr_unique_slug: avoids an existing scratch session" {
    # scratch には issue 番号のような鍵が無いので、同じ slug が二度出たら連番にする。
    # 上書きすると別の作業の README が消える
    mkdir -p "${BATS_TEST_TMPDIR}/.sessions/scratch-foo"
    run env PATH="${STUB}:${PATH}" zsh -c \
        "source '${HR}'; __hr_unique_slug '${BATS_TEST_TMPDIR}/.sessions' foo"
    [ "$status" -eq 0 ]
    [ "$output" = "foo-2" ]
}

@test "__hr_unique_slug: keeps the slug when nothing collides" {
    run env PATH="${STUB}:${PATH}" zsh -c \
        "source '${HR}'; __hr_unique_slug '${BATS_TEST_TMPDIR}/.sessions' bar"
    [ "$status" -eq 0 ]
    [ "$output" = "bar" ]
}

@test "hello-run: scratch does not require gh" {
    # issue を引かないので gh は要らない。必須にすると gh が無い環境で落ちる
    grep -q 'need=(herdr wt jq git)' "${HR}"
    grep -q '(( scratch )) || need+=(gh)' "${HR}"
}

@test "hello-run: scratch writes the task to README.md in the session dir" {
    # worktree の外（セッションディレクトリ直下）なので git を汚さない
    grep -q 'print -r -- "\$task" >"\$sdir/README.md"' "${HR}"
}

@test "hello-run: scratch asks for the task before drawing the progress ui" {
    # エディタと進捗表示のカーソル制御は同時に走らせられない
    read_line="$(grep -n '__hr_read_task "\$taskd/README.md"' "${HR}" | head -1 | cut -d: -f1)"
    draw_line="$(grep -n '"ブランチ名を推定" "やりたいことを記録"' "${HR}" | head -1 | cut -d: -f1)"
    [ -n "${read_line}" ] && [ -n "${draw_line}" ]
    [ "${read_line}" -lt "${draw_line}" ]
}

@test "hello-run: scratch skips the existing-tab shortcut" {
    # scratch は毎回新しい作業。ラベルで既存タブを拾うと別の作業に飛ばされる
    grep -q 'if (( ! scratch )); then' "${HR}"
}
