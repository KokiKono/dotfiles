#!/usr/bin/env bats

load ../test_helper

PLUGIN="home/dot_config/herdr/plugins/hello-run"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    PICK="${REPO_ROOT}/${PLUGIN}/executable_pick.zsh"
    ISSUES="${REPO_ROOT}/${PLUGIN}/executable_issues.zsh"
}

@test "pick.zsh / issues.zsh: valid zsh syntax" {
    run zsh -n "${PICK}"
    [ "$status" -eq 0 ]
    run zsh -n "${ISSUES}"
    [ "$status" -eq 0 ]
}

@test "pick.zsh: no --bind reload() payload contains a comma" {
    # fzf の --bind はコンマでバインドを区切るので、reload() の中にコンマがあると
    # 起動時に rc=2 で即死する（popup が一瞬で開いて閉じる）。jq を直接埋めて
    # これを踏んだので、コンマの有無を直接見張る。
    # fzf 自身に食わせて確かめるには tty が要り CI で落ちるため、ここでは文字列を見る。
    run grep -o -- '--bind="[^"]*"' "${PICK}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c .)" -ge 1 ]
    while read -r bind; do
        payload="${bind#*reload(}"
        [ "${payload}" = "${bind}" ] && continue   # reload() ではないバインド
        payload="${payload%)\"}"
        [[ "${payload}" != *,* ]] || {
            echo "reload() にコンマが入っている: ${bind}" >&2
            false
        }
    done <<<"$output"
}

@test "pick.zsh: the query lives in issues.zsh, not inline in a --bind" {
    # jq のフィルタが --bind の中に戻っていないこと
    run grep -- '--bind=.*jq' "${PICK}"
    [ "$status" -ne 0 ]
    grep -q 'issues.zsh' "${PICK}"
}

@test "issues.zsh: requires HELLO_RUN_ISSUE_ORG" {
    run env -u HELLO_RUN_ISSUE_ORG zsh "${ISSUES}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"HELLO_RUN_ISSUE_ORG"* ]]
}

@test "issues.zsh: emits url in column 1 and one aligned display column" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"url":"https://github.com/org/a/issues/12","repository":{"name":"short"},"number":12,"title":"hello"},
       {"url":"https://github.com/org/b/issues/3456","repository":{"name":"much-longer-name"},"number":3456,"title":"world"}]'
EOF
    chmod +x "${STUB}/gh"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_ISSUE_ORG=org zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    # 1 列目は URL。番号はリポジトリ間で一意でないので hello-run には URL を渡す
    [[ "${lines[0]}" == "https://github.com/org/a/issues/12	"* ]]
    [[ "${lines[1]}" == "https://github.com/org/b/issues/3456	"* ]]
    # 2 列目は fzf にそのまま見せる桁揃え済みの 1 列。タイトルの開始位置が揃うこと
    first="${lines[0]#*	}"; second="${lines[1]#*	}"
    pre1="${first%%hello*}"; pre2="${second%%world*}"
    [ "${pre1}" != "${first}" ]
    [ "${#pre1}" -eq "${#pre2}" ]
}

@test "issues.zsh: marks what already exists (tab / worktree / nothing)" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    STUB="${BATS_TEST_TMPDIR}/bin"
    ROOT="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${STUB}" "${ROOT}/.sessions/issue-12" "${ROOT}/.sessions/issue-34"
    cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"url":"https://github.com/org/a/issues/12","repository":{"name":"a"},"number":12,"title":"tab もある"},
       {"url":"https://github.com/org/a/issues/34","repository":{"name":"a"},"number":34,"title":"worktree だけ"},
       {"url":"https://github.com/org/a/issues/56","repository":{"name":"a"},"number":56,"title":"まだ何も無い"}]'
EOF
    # issue-12 のタブだけが、しかも別の workspace にある
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}}' ;;
  "tab list")
    if [[ "$*" == *"--workspace w2"* ]]; then
      echo '{"result":{"tabs":[{"tab_id":"w2:tA","label":"issue-12"}]}}'
    else
      echo '{"result":{"tabs":[]}}'
    fi ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/gh" "${STUB}/herdr"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_ISSUE_ORG=org HELLO_RUN_ROOT="${ROOT}"         zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"●"*"12"*"tab もある"* ]]
    [[ "$output" == *"○"*"34"*"worktree だけ"* ]]
    [[ "$output" == *"・"*"56"*"まだ何も無い"* ]]
}

@test "issues.zsh: looks for tabs in every workspace, not just the current one" {
    # 印と hello-run の挙動を揃えるため。現在の workspace だけ見ると、別 workspace に
    # あるタブを「無い」と表示してしまう
    grep -q 'workspace list' "${ISSUES}"
    run grep -- 'tab list --workspace "$HERDR_WORKSPACE_ID"' "${ISSUES}"
    [ "$status" -ne 0 ]
}

@test "issues.zsh: searches the whole org for issues assigned to me" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    cat >"${STUB}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >"${BATS_TEST_TMPDIR}/args"
echo '[]'
EOF
    chmod +x "${STUB}/gh"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_ISSUE_ORG=org zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    # リポジトリ単位の issue list ではなく org 横断の search を使うこと
    grep -q "^search issues " "${BATS_TEST_TMPDIR}/args"
    grep -q -- "--owner org" "${BATS_TEST_TMPDIR}/args"
    grep -q -- "--assignee @me" "${BATS_TEST_TMPDIR}/args"
    run grep -q -- "--repo" "${BATS_TEST_TMPDIR}/args"
    [ "$status" -ne 0 ]
}

@test "pick.zsh: offers no escape hatch to everyone else's issues" {
    # 「自分の issue だけ」が仕様。全件表示に戻す bind が復活していないこと
    run grep -E -- '--bind=.*(ctrl-a|all)' "${PICK}"
    [ "$status" -ne 0 ]
    grep -q 'アサインされた open issue がありません' "${PICK}"
}

@test "pick.zsh: reload is a plain key, not a ctrl chord" {
    # ctrl-r は端末の履歴検索と当たるので素の r にしてある。
    # 素のキーをバインドするには絞り込みを切る必要がある（--disabled）。
    grep -q -- '--disabled' "${PICK}"
    grep -q -- '--bind="r:reload(' "${PICK}"
    run grep -- '--bind="ctrl-' "${PICK}"
    [ "$status" -ne 0 ]
    # 絞り込みが無いと打った文字が入力欄に残るので消していること
    grep -q -- "--bind='change:clear-query'" "${PICK}"
}

@test "pick.zsh: hands hello-run the url, not the bare number" {
    # 番号はリポジトリ間で一意でないため
    grep -q 'hello-run "$url"' "${PICK}"
    run grep -- 'hello-run "$num"' "${PICK}"
    [ "$status" -ne 0 ]
}

@test "pick.zsh: derives the org from HELLO_RUN_ISSUE_REPO, hardcoding none" {
    # public リポジトリなので org 名は持たず ~/.pzshrc から取ること
    grep -q 'HELLO_RUN_ISSUE_ORG:-${HELLO_RUN_ISSUE_REPO%%/\*}' "${PICK}"
}
