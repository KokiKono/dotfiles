#!/usr/bin/env bats

load ../test_helper

SRC="home/dot_config/zsh/hello-debug.zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    HD="${REPO_ROOT}/${SRC}"
    STUB="${BATS_TEST_TMPDIR}/bin"
    CONF="${BATS_TEST_TMPDIR}/conf"
    export HERDR_LOG="${BATS_TEST_TMPDIR}/herdr.log"
    export DS_PANES="${BATS_TEST_TMPDIR}/panes.tsv"
    mkdir -p "${STUB}" "${CONF}"
    : >"${HERDR_LOG}"
    # hello-run の配置: <root>/.sessions/scratch-x/{front,back}
    SESSION="${BATS_TEST_TMPDIR}/root/.sessions/scratch-x"
    mkdir -p "${SESSION}/front" "${SESSION}/back"
    # hello-run が作るタブ（main / front / back）
    printf 'w1:p1\tw1:t1\tmain\t%s\n' "${SESSION}" >"${DS_PANES}"
    printf 'w1:p2\tw1:t1\tfront\t%s\n' "${SESSION}/front" >>"${DS_PANES}"
    printf 'w1:p3\tw1:t1\tback\t%s\n' "${SESSION}/back" >>"${DS_PANES}"
    make_stubs
    write_config
}

# pane の状態は DS_PANES（pane_id \t tab_id \t label \t cwd）に持たせる。
# pane read は HD_READ の中身を返す。
make_stubs() {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${HERDR_LOG}"
cwd=""
for ((i=1; i<=$#; i++)); do [[ "${!i}" == "--cwd" ]] && cwd="${@:i+1:1}"; done
case "$1 $2" in
  "workspace list")
    echo '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}' ;;
  "tab list")
    echo '{"result":{"tabs":[{"tab_id":"w1:t1","label":"scratch-x"}]}}' ;;
  "pane list")
    jq -Rn '[inputs | split("\t") | {pane_id:.[0], tab_id:.[1], label:.[2], cwd:.[3]}]
            | {result:{panes:.}}' <"${DS_PANES}" ;;
  "pane split")
    n=$(( $(wc -l <"${DS_PANES}") + 1 ))
    printf 'w1:p%s\tw1:t1\t\t%s\n' "$n" "${cwd}" >>"${DS_PANES}"
    echo "{\"result\":{\"pane\":{\"pane_id\":\"w1:p${n}\"}}}" ;;
  "pane rename")
    awk -F'\t' -v OFS='\t' -v p="$3" -v l="$4" '$1==p{$3=l}1' "${DS_PANES}" >"${DS_PANES}.t"
    mv "${DS_PANES}.t" "${DS_PANES}"
    echo '{}' ;;
  "pane close")
    awk -F'\t' -v p="$3" '$1!=p' "${DS_PANES}" >"${DS_PANES}.t"
    mv "${DS_PANES}.t" "${DS_PANES}"
    echo '{}' ;;
  "pane read")
    if [[ -n "${HD_SCROLL:-}" ]]; then
      # 1 回目はマーカーだけ、2 回目以降はマーカーが流れ出て失敗行だけが見える
      if [[ ! -e "${HD_SCROLL}" ]]; then
        : >"${HD_SCROLL}"
        n=$(grep -o "hello-debug-run-%s\\\\n' [0-9]*" "${HERDR_LOG}" | tail -n 1 | awk '{print $NF}')
        echo "hello-debug-run-${n}"
      else
        echo "boom"
      fi
    fi
    [[ -n "${HD_READ:-}" ]] && cat "${HD_READ}" ;;
  *) echo '{}' ;;
esac
EOF
    # curl は HD_CODE（既定 200）を返す。-w を付けない呼び出し（__ds_http_ok の -I）も同じ値
    printf '#!/usr/bin/env bash\necho "${HD_CODE:-200}"\n' >"${STUB}/curl"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${STUB}/lsof"
    chmod +x "${STUB}/herdr" "${STUB}/curl" "${STUB}/lsof"
}

write_config() {
    cat >"${CONF}/front.json" <<'EOF'
{ "apps": [
  { "name": "web", "cmd": "runner web --port {{port}}", "base_port": 4000,
    "ready_regex": "ready", "url": "http://localhost:{{port}}" },
  { "name": "admin", "cmd": "runner admin --port {{port}}", "base_port": 8000,
    "ready_regex": "ready", "url": "http://localhost:{{port}}" }
] }
EOF
    cat >"${CONF}/hello-debug.json" <<'EOF'
{ "front_repo": "front",
  "backend": { "name": "backend", "repo": "back",
    "cmd": "runner backend", "stop_cmd": "true",
    "host_cmd": "echo proj.localhost", "url": "http://app.{{host}}/",
    "ready_timeout_ms": 2000, "failure_regex": "boom",
    "notes": ["api: http://api.{{host}}"] } }
EOF
}

run_hd() {
    run env PATH="${STUB}:${PATH}" HERDR_ENV=1 HERDR_TAB_ID=w1:t1 \
        HELLO_DEBUG_CONFIG="${CONF}/hello-debug.json" DEV_SERVER_CONFIG_DIR="${CONF}" \
        HELLO_DEBUG_POLL=1 DEV_SERVER_STOP_WAIT=1 DEV_SERVER_HTTP_WAIT=1 "$@" \
        zsh -c "source '${HD}'; cd '${HD_CWD:-${SESSION}}'; hello-debug ${HD_ARGS}"
}

label_of() { awk -F'\t' -v p="$1" '$1==p{print $3}' "${DS_PANES}"; }

@test "hello-debug.zsh: valid zsh syntax" {
    run zsh -n "${HD}"
    [ "$status" -eq 0 ]
}

@test "hello-debug: refuses to run outside a hello-run session" {
    mkdir -p "${BATS_TEST_TMPDIR}/elsewhere"
    HD_CWD="${BATS_TEST_TMPDIR}/elsewhere" HD_ARGS="--json" run_hd
    [ "$status" -eq 1 ]
    [[ "$output" == *".sessions"* ]] || false
}

@test "hello-debug: never creates a tab when the session tab is missing" {
    # タブを作らないのが dev-server との違い。見つからなければ止まる
    : >"${DS_PANES}"
    HD_ARGS="--json" run_hd env HERDR_TAB_ID=
    [ "$status" -eq 1 ]
    ! grep -q '^tab create' "${HERDR_LOG}"
}

@test "hello-debug: starts the backend in a pane split right of the repo pane" {
    HD_ARGS="--json" run_hd
    [ "$status" -eq 0 ]
    grep -q '^pane split w1:p3 --direction right' "${HERDR_LOG}"
    [ "$(label_of w1:p4)" = "backend:proj.localhost" ]
    [ "$(echo "$output" | jq -r '.apps[0].status')" = "started" ]
    [ "$(echo "$output" | jq -r '.notes[0]')" = "api: http://api.proj.localhost" ]
}

@test "hello-debug: leaves a running backend alone and reuses its pane" {
    printf 'w1:p4\tw1:t1\tbackend:proj.localhost\t%s\n' "${SESSION}/back" >>"${DS_PANES}"
    HD_ARGS="--json" run_hd
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.apps[0].status')" = "running" ]
    ! grep -q '^pane split' "${HERDR_LOG}"
    ! grep -q '^pane run' "${HERDR_LOG}"
}

@test "hello-debug: treats proxy 502 as not ready" {
    # リバースプロキシの 502 を起動済みと取り違えないこと
    HD_ARGS="--json" run_hd env HD_CODE=502
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.apps[0].status')" = "failed" ]
}

@test "hello-debug: treats an app 500 as running" {
    # 未適用のマイグレーション等でアプリが返す 500 は、起動したうえでの失敗
    HD_ARGS="--json" run_hd env HD_CODE=500
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.apps[0].status')" = "started" ]
}

@test "hello-debug: ignores failure text left from before this run" {
    # 前回の失敗がスクロールバックに残っていても、今回の失敗とは見なさない
    printf 'boom\n' >"${BATS_TEST_TMPDIR}/read.txt"
    HD_ARGS="--json" run_hd env HD_CODE=000 HD_READ="${BATS_TEST_TMPDIR}/read.txt"
    [ "$status" -eq 1 ]
    [[ "$(echo "$output" | jq -r '.apps[0].detail')" == *"応答しませんでした"* ]] || false
}

@test "hello-debug: catches a failure after the marker scrolled out" {
    # ログの多い setup ではマーカーが読み取り範囲から流れ出る。それでも失敗を拾うこと
    HD_ARGS="--json" run_hd env HD_CODE=000 HD_SCROLL="${BATS_TEST_TMPDIR}/scrolled"
    [ "$status" -eq 1 ]
    [[ "$(echo "$output" | jq -r '.apps[0].detail')" == boom* ]] || false
}

@test "hello-debug: stacks front apps right of the front pane, then downward" {
    HD_ARGS="web admin --no-backend --json" run_hd
    [ "$status" -eq 0 ]
    grep -q '^pane split w1:p2 --direction right' "${HERDR_LOG}"
    grep -q '^pane split w1:p4 --direction down' "${HERDR_LOG}"
    [ "$(label_of w1:p4)" = "web:4000" ]
    [ "$(label_of w1:p5)" = "admin:8000" ]
}

@test "hello-debug: stop without args closes only the panes it added" {
    printf 'w1:p4\tw1:t1\tbackend:proj.localhost\t%s\n' "${SESSION}/back" >>"${DS_PANES}"
    printf 'w1:p5\tw1:t1\tweb:4000\t%s\n' "${SESSION}/front" >>"${DS_PANES}"
    HD_ARGS="stop --json" run_hd
    [ "$status" -eq 0 ]
    [ "$(wc -l <"${DS_PANES}" | tr -d ' ')" = "3" ]
    [ "$(echo "$output" | jq -r '.apps | length')" = "2" ]
}
