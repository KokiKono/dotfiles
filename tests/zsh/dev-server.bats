#!/usr/bin/env bats

load ../test_helper

SRC="home/dot_config/zsh/dev-server.zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"
    DS="${REPO_ROOT}/${SRC}"
    STUB="${BATS_TEST_TMPDIR}/bin"
    CONF="${BATS_TEST_TMPDIR}/conf"
    export HERDR_LOG="${BATS_TEST_TMPDIR}/herdr.log"
    export DS_PANES="${BATS_TEST_TMPDIR}/panes.tsv"
    mkdir -p "${STUB}" "${CONF}"
    : >"${HERDR_LOG}"
    : >"${DS_PANES}"
    make_stubs
    # <root>/.sessions/issue-42/myrepo という hello-run の配置を作る
    WT="${BATS_TEST_TMPDIR}/root/.sessions/issue-42/myrepo"
    mkdir -p "${WT}"
    git -C "${WT}" init -q .
}

# pane の状態は DS_PANES（pane_id \t tab_id \t label \t cwd）に持たせ、
# split / rename で書き換える。pane list はそれを JSON にして返す。
make_stubs() {
    cat >"${STUB}/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${HERDR_LOG}"
cwd=""
# pane の cwd は herdr が覚えるので、タブの同一性判定のために記録しておく
for ((i=1; i<=$#; i++)); do [[ "${!i}" == "--cwd" ]] && cwd="${@:i+1:1}"; done
case "$1 $2" in
  "workspace list")
    echo '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}' ;;
  "tab list")
    if [[ -s "${DS_PANES}" ]]; then
      echo '{"result":{"tabs":[{"tab_id":"w1:t1","label":"dev-issue-42"}]}}'
    else
      echo '{"result":{"tabs":[]}}'
    fi ;;
  "tab create")
    printf 'w1:p1\tw1:t1\t\t%s\n' "${cwd}" >>"${DS_PANES}"
    echo '{"result":{"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}' ;;
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
  *) echo '{}' ;;
esac
EOF
    # LISTEN 中のポートは DS_BUSY（"port:cwd" を空白区切り）で与える
    cat >"${STUB}/lsof" <<'EOF'
#!/usr/bin/env bash
port=""
for a in "$@"; do case "$a" in -iTCP:*) port="${a#-iTCP:}";; esac; done
if [[ -n "$port" ]]; then
  for e in ${DS_BUSY:-}; do [[ "${e%%:*}" == "$port" ]] && echo "pid${port}"; done
  exit 0
fi
pid="$2"
for e in ${DS_BUSY:-}; do [[ "pid${e%%:*}" == "$pid" ]] && echo "n${e#*:}"; done
EOF
    printf '#!/usr/bin/env bash\necho 200\n' >"${STUB}/curl"
    chmod +x "${STUB}/herdr" "${STUB}/lsof" "${STUB}/curl"
}

write_config() {
    cat >"${CONF}/myrepo.json" <<EOF
{
  "apps": [
    { "name": "web", "cmd": "runner start --port {{port}}", "base_port": 4000,
      "ready_regex": "web is waiting on", "url": "http://localhost:{{port}}" },
    { "name": "metro", "cmd": "runner metro", "base_port": 8081, "port_fixed": true,
      "ready_regex": "metro waiting on", "url": "", "check_http": false }
  ]
}
EOF
}

# dev-server をスタブ環境で走らせる
run_ds() {
    run env PATH="${STUB}:${PATH}" HERDR_ENV=1 DEV_SERVER_CONFIG_DIR="${CONF}" \
        DEV_SERVER_STOP_WAIT=1 DEV_SERVER_HTTP_WAIT=1 "$@" \
        zsh -c "source '${DS}'; cd '${WT}'; dev-server ${DS_ARGS}"
}

run_fn() {
    local expr="$1"; shift
    run env PATH="${STUB}:${PATH}" "$@" zsh -c "source '${DS}'; ${expr}"
}

@test "dev-server.zsh: valid zsh syntax" {
    run zsh -n "${DS}"
    [ "$status" -eq 0 ]
}

# --- 文脈 ---------------------------------------------------------------------

@test "__ds_context: derives the label from the hello-run session layout" {
    run env PATH="${STUB}:${PATH}" zsh -c "source '${DS}'; cd '${WT}'; __ds_context"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\t'"dev-issue-42" ]] || false
    [[ "$output" == "myrepo"$'\t'* ]] || false
}

@test "__ds_context: falls back to the repo name outside a session dir" {
    plain="${BATS_TEST_TMPDIR}/plain/solo"
    mkdir -p "${plain}"
    git -C "${plain}" init -q .
    run env PATH="${STUB}:${PATH}" zsh -c "source '${DS}'; cd '${plain}'; __ds_context"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\t'"dev-solo" ]] || false
}

# --- ポート -------------------------------------------------------------------

@test "__ds_pick_port: takes the base port when it is free" {
    run_fn '__ds_pick_port 4000 0 /mine'
    [ "$status" -eq 0 ]
    [ "$output" = "ok"$'\t'"4000" ]
}

@test "__ds_pick_port: walks up when another worktree holds the base port" {
    # 別 worktree が同じアプリを動かしていても、こちらは別ポートで立てられること
    run_fn '__ds_pick_port 4000 0 /mine' DS_BUSY="4000:/other/wt"
    [ "$status" -eq 0 ]
    [ "$output" = "ok"$'\t'"4001" ]
}

@test "__ds_pick_port: skips a port held by another app of this worktree" {
    # 自分の worktree が握っていても、preferred でなければ別のアプリなので奪わない
    run_fn '__ds_pick_port 4000 0 /mine' DS_BUSY="4000:/mine/repo"
    [ "$status" -eq 0 ]
    [ "$output" = "ok"$'\t'"4001" ]
}

@test "__ds_pick_port: keeps the port this app already holds" {
    run_fn '__ds_pick_port 4000 0 /mine 4005' DS_BUSY="4005:/mine/repo"
    [ "$status" -eq 0 ]
    [ "$output" = "ok"$'\t'"4005" ]
}

@test "__ds_pick_port: refuses a fixed port held by another worktree" {
    # 別ブランチのサーバーを自分のものだと思って確認する事故を防ぐ要の判定
    run_fn '__ds_pick_port 8081 1 /mine' DS_BUSY="8081:/other/wt"
    [ "$status" -eq 3 ]
    [ "$output" = "conflict"$'\t'"/other/wt" ]
}

@test "__ds_pick_port: reclaims a fixed port held by this worktree" {
    run_fn '__ds_pick_port 8081 1 /mine' DS_BUSY="8081:/mine/repo"
    [ "$status" -eq 0 ]
    [ "$output" = "ok"$'\t'"8081" ]
}

# --- 設定 ---------------------------------------------------------------------

@test "dev-server: exits 2 and points at the example when the config is missing" {
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 2 ]
    [[ "$output" == *"apps.example.json"* ]] || false
}

@test "dev-server: exits 2 for an app that is not in the config" {
    write_config
    DS_ARGS="nope --json" run_ds
    [ "$status" -eq 2 ]
    [[ "$output" == *"nope"* ]] || false
}

@test "dev-server: refuses to run outside herdr" {
    write_config
    run env -u HERDR_ENV PATH="${STUB}:${PATH}" DEV_SERVER_CONFIG_DIR="${CONF}" \
        zsh -c "source '${DS}'; cd '${WT}'; dev-server web"
    [ "$status" -eq 2 ]
    [[ "$output" == *"HERDR_ENV"* ]] || false
}

# --- 起動 ---------------------------------------------------------------------

@test "dev-server: creates the tab and substitutes the port into cmd and url" {
    write_config
    DS_ARGS="web --json" run_ds DS_BUSY="4000:/other/wt"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.apps[0].port' <<<"$output")" = "4001" ]
    [ "$(jq -r '.apps[0].url' <<<"$output")" = "http://localhost:4001" ]
    [ "$(jq -r '.apps[0].status' <<<"$output")" = "started" ]
    [ "$(jq -r '.label' <<<"$output")" = "dev-issue-42" ]
    grep -q 'tab create .*--label dev-issue-42' "${HERDR_LOG}"
    grep -qF 'pane run w1:p1 runner start --port 4001' "${HERDR_LOG}"
}

@test "dev-server: labels the pane with app and port" {
    # pane の label が次回この pane を見つける唯一の手掛かり
    write_config
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 0 ]
    grep -qF 'pane rename w1:p1 web:4000' "${HERDR_LOG}"
}

@test "dev-server: waits on both the ready line and the failure line" {
    # 成功語だけ待つと、落ちたときタイムアウトまで無言になる
    write_config
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 0 ]
    rx="$(grep 'pane wait-output' "${HERDR_LOG}")"
    [[ "$rx" == *"web is waiting on"* ]] || false
    [[ "$rx" == *"command not found"* ]] || false
    [[ "$rx" == *"(?i)"* ]] || false
}

@test "dev-server: restarts in the same pane instead of splitting again" {
    write_config
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 0 ]
    : >"${HERDR_LOG}"
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 0 ]
    [ "$(jq -r '.apps[0].status' <<<"$output")" = "restarted" ]
    grep -qF 'pane send-keys w1:p1 ctrl+c' "${HERDR_LOG}"
    grep -qF 'pane run w1:p1' "${HERDR_LOG}"
    run grep -c 'pane split' "${HERDR_LOG}"
    [ "$output" = "0" ]
}

@test "dev-server: puts the second app in the same tab as a new pane" {
    write_config
    DS_ARGS="web --json" run_ds
    [ "$status" -eq 0 ]
    : >"${HERDR_LOG}"
    DS_ARGS="metro --json" run_ds
    [ "$status" -eq 0 ]
    run grep -c 'tab create' "${HERDR_LOG}"
    [ "$output" = "0" ]
    grep -q 'pane split w1:p1' "${HERDR_LOG}"
    grep -qF 'pane rename w1:p2 metro:8081' "${HERDR_LOG}"
}

@test "dev-server: reports a conflict without starting anything" {
    write_config
    DS_ARGS="metro --json" run_ds DS_BUSY="8081:/other/wt"
    [ "$status" -eq 1 ]
    [ "$(jq -r '.apps[0].status' <<<"$output")" = "conflict" ]
    [[ "$(jq -r '.apps[0].detail' <<<"$output")" == *"/other/wt"* ]] || false
    run grep -c 'pane run' "${HERDR_LOG}"
    [ "$output" = "0" ]
}

@test "dev-server: list does not create a tab" {
    # 見るだけの list でタブが増えると、このツールが解こうとしている
    # 「どこで何が動いているか分からない」に戻る
    write_config
    DS_ARGS="list --json" run_ds
    [ "$status" -eq 0 ]
    run grep -c 'tab create' "${HERDR_LOG}"
    [ "$output" = "0" ]
}
