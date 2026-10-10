#!/usr/bin/env bats

load ../test_helper

PLUGIN="home/dot_config/herdr/plugins/hello-run"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    PICK="${REPO_ROOT}/${PLUGIN}/executable_pick.zsh"
    ISSUES="${REPO_ROOT}/${PLUGIN}/executable_issues.zsh"
    # 実キャッシュ（~/.cache/hello-run）を読み書きしないよう、テストごとに隔離する
    CACHE="${BATS_TEST_TMPDIR}/cache"
    export HELLO_RUN_CACHE_DIR="${CACHE}"
    # ~/.pzshrc を拾って実 org に繋がらないようにする
    export HELLO_RUN_PRIVATE_RC="${BATS_TEST_TMPDIR}/no-such-rc"
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
    run env -u HELLO_RUN_ISSUE_ORG -u HELLO_RUN_ISSUE_REPO \
        HELLO_RUN_PRIVATE_RC="${BATS_TEST_TMPDIR}/no-such-rc" zsh "${ISSUES}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"HELLO_RUN_ISSUE_ORG"* ]] || false
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
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    # 1 列目は URL。番号はリポジトリ間で一意でないので hello-run には URL を渡す
    [[ "${lines[0]}" == "https://github.com/org/a/issues/12	"* ]] || false
    [[ "${lines[1]}" == "https://github.com/org/b/issues/3456	"* ]] || false
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
    # issue-12 のタブだけが、しかも別の workspace にある。
    # ● を付けるにはラベルだけでなくペインがセッションディレクトリに居ることも要る
    cat >"${STUB}/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"}]}}' ;;
  "tab list")
    if [[ "\$*" == *"--workspace w2"* ]]; then
      echo '{"result":{"tabs":[{"tab_id":"w2:tA","label":"issue-12"}]}}'
    else
      echo '{"result":{"tabs":[]}}'
    fi ;;
  "pane list") echo '{"result":{"panes":[{"tab_id":"w2:tA","cwd":"${ROOT}/.sessions/issue-12/a"}]}}' ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/gh" "${STUB}/herdr"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org HELLO_RUN_ROOT="${ROOT}"         zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"●"*"12"*"tab もある"* ]] || false
    [[ "$output" == *"○"*"34"*"worktree だけ"* ]] || false
    [[ "$output" == *"・"*"56"*"まだ何も無い"* ]] || false
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
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org zsh "${ISSUES}"
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

@test "pick.zsh: r bypasses the cache" {
    # キャッシュがあるぶん、r は「取り直し」である必要がある
    grep -q -- '--bind="r:reload(${(q)issues} --refresh)"' "${PICK}"
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

# --- キャッシュ ---------------------------------------------------------------

# 呼ばれた回数を数える gh。CALLS に 1 行ずつ足す。
stub_gh() {
    STUB="${BATS_TEST_TMPDIR}/bin"
    CALLS="${BATS_TEST_TMPDIR}/gh.calls"
    mkdir -p "${STUB}"
    : >"${CALLS}"
    cat >"${STUB}/gh" <<EOF
#!/usr/bin/env bash
echo call >>"${CALLS}"
[ -n "\${GH_FAIL:-}" ] && exit 1
echo '[{"url":"https://github.com/org/a/issues/12","repository":{"name":"a"},"number":12,"title":"hello"}]'
EOF
    chmod +x "${STUB}/gh"
}

run_issues() {
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        "$@" zsh "${ISSUES}"
}

@test "issues.zsh: second run serves the cache without calling gh" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    run_issues
    [ "$status" -eq 0 ]
    [ "$(grep -c . "${CALLS}")" -eq 1 ]
    run_issues
    [ "$status" -eq 0 ]
    [[ "$output" == *"12"*"hello"* ]] || false
    # gh は増えていないこと
    [ "$(grep -c . "${CALLS}")" -eq 1 ]
}

@test "issues.zsh: --refresh always calls gh" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    run_issues
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        zsh "${ISSUES}" --refresh
    [ "$status" -eq 0 ]
    [ "$(grep -c . "${CALLS}")" -eq 2 ]
}

@test "issues.zsh: an expired cache is refetched" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    run_issues
    find "${CACHE}" -name 'issues-*.tsv' -exec touch -t 202001010000 {} +
    run_issues
    [ "$status" -eq 0 ]
    [ "$(grep -c . "${CALLS}")" -eq 2 ]
}

@test "issues.zsh: --warm fills the cache and prints nothing" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        zsh "${ISSUES}" --warm
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -s "${CACHE}/issues-org.tsv" ]
    # 温めてあるので次は gh を呼ばない
    run_issues
    [ "$(grep -c . "${CALLS}")" -eq 1 ]
    [[ "$output" == *"hello"* ]] || false
}

@test "issues.zsh: falls back to the cache when gh fails" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    run_issues
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        GH_FAIL=1 zsh "${ISSUES}" --refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello"* ]] || false
}

@test "issues.zsh: gives up when gh fails and there is no cache" {
    stub_gh
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        GH_FAIL=1 zsh "${ISSUES}"
    [ "$status" -ne 0 ]
}

@test "issues.zsh: marks are recomputed on a cache hit, not cached" {
    # 印は worktree / タブの有無なので、キャッシュに焼き付けると嘘になる
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_gh
    ROOT="${BATS_TEST_TMPDIR}/root"
    run_issues
    [[ "$output" == *"・"* ]] || false
    # キャッシュはそのままに、worktree だけ後から生やす
    mkdir -p "${ROOT}/.sessions/issue-12"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        HELLO_RUN_ROOT="${ROOT}" zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"○"* ]] || false
    [ "$(grep -c . "${CALLS}")" -eq 1 ]
}

@test "herdr-plugin.toml: warms the cache on startup" {
    grep -q 'issues.zsh", "--warm' "${REPO_ROOT}/${PLUGIN}/herdr-plugin.toml"
}

@test "issues.zsh: marks a tab only when its panes are in the session directory" {
    # ラベルだけ同じ別物に ● が付くと、enter でそこへ飛ばされる。hello-run の
    # 切り替え判定（__hr_find_tab）と同じ条件で印を付けること
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    STUB="${BATS_TEST_TMPDIR}/bin"
    ROOT="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${STUB}" "${ROOT}/.sessions/issue-12" "${ROOT}/.sessions/issue-34"
    cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"url":"https://github.com/org/a/issues/12","repository":{"name":"a"},"number":12,"title":"正しいタブ"},
       {"url":"https://github.com/org/a/issues/34","repository":{"name":"a"},"number":34,"title":"ラベルだけ一致"}]'
EOF
    # issue-12 のタブはセッションディレクトリに居る。issue-34 のタブはラベルだけ同じで別物
    cat >"${STUB}/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w1"}]}}' ;;
  "tab list") echo '{"result":{"tabs":[{"tab_id":"w1:tA","label":"issue-12"},{"tab_id":"w1:tB","label":"issue-34"}]}}' ;;
  "pane list")
    echo '{"result":{"panes":[{"tab_id":"w1:tA","cwd":"${ROOT}/.sessions/issue-12/a"},
                              {"tab_id":"w1:tB","cwd":"/somewhere/else"}]}}' ;;
  *) echo '{}' ;;
esac
EOF
    chmod +x "${STUB}/gh" "${STUB}/herdr"
    run env PATH="${STUB}:${PATH}" HELLO_RUN_CACHE_DIR="${CACHE}" HELLO_RUN_ISSUE_ORG=org \
        HELLO_RUN_ROOT="${ROOT}" zsh "${ISSUES}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"●"*"12"*"正しいタブ"* ]] || false
    # worktree はあるがタブは別物なので ○ まで
    [[ "$output" == *"○"*"34"*"ラベルだけ一致"* ]] || false
}
