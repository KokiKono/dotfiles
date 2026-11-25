# herdr を叩く zsh モジュール（hello-run / dev-server / herdr プラグイン）の共通部分。
# 依存: jq。TUI では herdr、app では herdr-app と hc（herdr-core）。
#
# ここに置くのは、herdr の扱いで一度はまった下の 1〜3 と、TUI と app の差だけ。コピーして
# 2 本持つと、片方だけ直したときに、たとえばピッカーの一覧に出す「タブあり」の印と
# hello-run が実際に飛ぶ先がずれて、どちらが正しいか分からなくなる。
#
#   1. タブの探索を現在の workspace に固定しない（タブは作ったときの workspace に残る）
#   2. ラベルの一致だけでタブを同一視しない（issue 番号はリポジトリ間で一意でない）
#   3. プラグインの pane には HERDR_WORKSPACE_ID が渡ってこない
#
# herdr には TUI（herdr コマンド）とデスクトップの app（Herdr.app）の 2 つがあり、
# 移行のあいだは両方を使う。呼び出し側は __hz_* だけを使い、どちらで動いているかを
# 気にしない。用語の対応は workspace = space、タブのラベル = タブの名前、
# ペイン = ペイン（app では中身のターミナルを hc の address で操作する）。

# hc と herdr-app は ~/.local/bin に入るが、プラグインを起動する `zsh -l` は
# ~/.zshrc を読まないので PATH に乗っていないことがある。先頭ではなく末尾に足すのは、
# テストが PATH の先頭に置くスタブを隠さないため。
[[ -d $HOME/.local/bin && :$PATH: != *:$HOME/.local/bin:* ]] && PATH=$PATH:$HOME/.local/bin

# __hz_backend → tui | app。
# app のターミナルには HC_TERMINAL_ID が入り、TUI のペインには HERDR_ENV が入る
# （TUI のプラグインのペインには HERDR_ENV が無く、HERDR_PLUGIN_CONTEXT_JSON だけが入る）。
# app のターミナルの中で TUI を動かしていると両方が入るので、内側の TUI を優先する。
# HERDR_BACKEND で明示もできる。どちらの印も無いときは TUI とみなし、__hz_require に
# 「herdr 環境ではない」と言わせる。
# __hz_is_app は同じ判定を終了ステータスで返す（関数の中の分岐はこちら。$(...) の fork が要らない）。
__hz_is_app() {
  case ${HERDR_BACKEND:-} in
    app) return 0 ;;
    tui) return 1 ;;
  esac
  [[ -z ${HERDR_ENV:-} && -z ${HERDR_PLUGIN_CONTEXT_JSON:-} && -n ${HC_TERMINAL_ID:-} ]]
}
__hz_backend() { if __hz_is_app; then print -r -- app; else print -r -- tui; fi }

# __hz_require → 今の backend を動かすのに要るものが揃っていなければ理由を stderr に出して 1。
__hz_require() {
  emulate -L zsh
  local c
  local -a need missing
  if __hz_is_app; then need=(herdr-app hc jq); else need=(herdr jq); fi
  for c in $need; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing} )) && { print -ru2 -- "未インストール: ${missing[*]}"; return 1; }
  __hz_is_app && return 0
  [[ -n ${HERDR_ENV:-} || -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] || {
    print -ru2 -- "herdr 環境ではありません（HERDR_ENV が未設定。Herdr.app なら HC_TERMINAL_ID が要る）"
    return 1
  }
}

# app の 1 コマンド。失敗すると herdr-app は {"error": ...} を出して 1 で終わる。
__hz_app_do() { herdr-app do "$@" 2>/dev/null }

# __hz_app_lookup <key> <value> <want> : herdr-app ls のターミナルのうち key が value のものの want。
# ペイン（pane）とターミナルの address（terminal）の対応を、どちら向きにもここで引く。
__hz_app_lookup() {
  emulate -L zsh
  herdr-app ls 2>/dev/null | jq -r --arg k "$1" --arg v "$2" --arg w "$3" \
    '[.spaces[]?.tabs[]?.terminals[]? | select(.[$k] == $v) | .[$w]] | first // empty'
}
__hz_app_terminal_of() { __hz_app_lookup pane "$1" terminal }

# __hz_app_wait <term> <timeout_ms> <jq の条件> : hc get の JSON が条件を満たすまで 0.5 秒おきに見る。
__hz_app_wait() {
  emulate -L zsh
  local term=$1 cond=$3
  integer timeout_ms=$2 waited=0
  until hc get "$term" --json 2>/dev/null | jq -e "$cond" >/dev/null 2>&1; do
    (( waited >= timeout_ms )) && return 1
    sleep 0.5
    (( waited += 500 ))
  done
}

# __hz_focused_cwds → 今フォーカスしているペインの cwd の候補を、確からしい順に 1 行ずつ。
# TUI の popup は元のペインの cwd を引き継がないので、herdr が渡す context JSON → pane list の
# focused の順に引く（popup は pane list に出ず、開いている間も focused は元のペインを指す）。
# app からはタブとして開き、terminal.open が元のペインの cwd で始めるので $PWD だけ。
# app の中で herdr pane list を叩くと、裏で動いている TUI のペインを拾ってしまう。
__hz_focused_cwds() {
  emulate -L zsh
  if ! __hz_is_app && command -v jq >/dev/null 2>&1; then
    [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] && print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" \
      | jq -r '[.focused_pane_cwd, .workspace_cwd] | map(select(. != null and . != "")) | .[]' 2>/dev/null
    command -v herdr >/dev/null 2>&1 && herdr pane list 2>/dev/null \
      | jq -r '[.result.panes[]? | select(.focused) | (.foreground_cwd // .cwd)] | .[]' 2>/dev/null
  fi
  print -r -- "$PWD"
}

# __hz_workspace_id → 今いる workspace（app では space）の id。特定できなければ 1 を返す。
# herdr はプラグインの pane に HERDR_WORKSPACE_ID を渡さない（代わりに
# HERDR_PLUGIN_CONTEXT_JSON に入れてくる）ので、popup から呼ばれた呼び出し元が
# 空の id を tab create に渡すと workspace_not_found で落ちる。
# app では、自分のターミナルに app が付けた herdr.space ラベルを読む。
__hz_workspace_id() {
  emulate -L zsh
  local ws=""
  if __hz_is_app; then
    ws=$(hc get "$HC_TERMINAL_ID" --json 2>/dev/null | jq -r '.labels["herdr.space"] // empty' 2>/dev/null)
    [[ -n $ws ]] || ws=$(herdr-app ls 2>/dev/null \
                           | jq -r '[.spaces[]? | select(.active) | .id] | first // empty' 2>/dev/null)
    [[ -n $ws ]] || return 1
    print -r -- "$ws"
    return 0
  fi
  ws=${HERDR_WORKSPACE_ID:-}
  if [[ -z $ws && -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]]; then
    ws=$(print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.workspace_id // empty' 2>/dev/null)
  fi
  if [[ -z $ws ]]; then
    ws=$(herdr workspace list 2>/dev/null \
           | jq -r '[.result.workspaces[]? | select(.focused) | .workspace_id] | first // empty')
  fi
  [[ -n $ws ]] || return 1
  print -r -- "$ws"
}

# __hz_tabs → 全 workspace のタブを "<workspace_id>\t<tab_id>\t<label>" で 1 行ずつ。
# ラベルの無いタブは label が空。app ではタブの名前をラベルとして扱う
# （名前の無いタブは 1, 2, ... と番号で呼ばれるので issue-<N> などとは当たらない）。
__hz_tabs() {
  emulate -L zsh
  if __hz_is_app; then
    herdr-app ls 2>/dev/null \
      | jq -r '.spaces[]? | .id as $s | .tabs[]? | "\($s)\t\(.id)\t\(.name // "")"' 2>/dev/null
    return 0
  fi
  local ws
  for ws in ${(f)"$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id // empty')"}; do
    [[ -n $ws ]] || continue
    herdr tab list --workspace "$ws" 2>/dev/null \
      | jq -r --arg w "$ws" '.result.tabs[]? | "\($w)\t\(.tab_id)\t\(.label // "")"' 2>/dev/null
  done
}

# __hz_tab_cwds → 全タブのペインを "<tab_id>\t<cwd>" で 1 行ずつ。
# app の cwd は hc が持つ「ターミナルを始めたディレクトリ」で、後から cd した先ではない。
# hello-run や dev-server はペインを目的のディレクトリで始めるので、判定にはこれで足りる。
__hz_tab_cwds() {
  emulate -L zsh
  if __hz_is_app; then
    local terms
    terms=$(hc ls --json 2>/dev/null) || return 0
    herdr-app ls 2>/dev/null | jq -r --argjson h "$terms" '
      ([$h.terminals[]? | {key: .address, value: (.cwd // "")}] | from_entries) as $cwd
      | .spaces[]?.tabs[]? | .id as $t | .terminals[]? | "\($t)\t\($cwd[.terminal] // "")"' 2>/dev/null
    return 0
  fi
  herdr pane list 2>/dev/null | jq -r '.result.panes[]? | "\(.tab_id)\t\(.cwd // "")"' 2>/dev/null
}

# __hz_tab_has_cwd_under <tab_id> <dir> [<__hz_tab_cwds の出力>] : そのタブのペインが dir の下に居るか。
# dir が空なら検証しない（真を返す）。一覧を渡せば取り直さない。
__hz_tab_has_cwd_under() {
  emulate -L zsh
  local tab=$1 dir=$2 t cwd
  [[ -n $dir ]] || return 0
  local cwds=${3-$(__hz_tab_cwds)}
  while IFS=$'\t' read -r t cwd; do
    [[ $t == "$tab" ]] || continue
    [[ $cwd == "$dir" || $cwd == "$dir/"* ]] && return 0
  done <<< "$cwds"
  return 1
}

# __hz_find_tab <label> [<dir>] → "<workspace_id><TAB><tab_id>"。無ければ 1 を返す。
# 現在の workspace だけでなく全部を見る。タブはそれを作ったときに居た workspace に
# 残るので、別の workspace から呼ぶと現在の workspace には無い。そこで見つけ損なうと、
# 既にあるのに同じラベルのタブをもう 1 つ作ってしまう。
# dir を渡すと、ラベルが一致したうえでペインが dir 配下に居ることまで確かめる。
__hz_find_tab() {
  emulate -L zsh
  local label=$1 dir=${2:-} ws tab l cwds
  [[ -n $dir ]] && cwds=$(__hz_tab_cwds)
  while IFS=$'\t' read -r ws tab l; do
    [[ -n $tab && $l == "$label" ]] || continue
    __hz_tab_has_cwd_under "$tab" "$dir" "$cwds" || continue
    print -r -- "$ws"$'\t'"$tab"
    return 0
  done < <(__hz_tabs)
  return 1
}

# __hz_focus_tab <workspace_id> <tab_id> : そのタブを表示する。
# tab focus だけでは別 workspace のタブに移れないので、先に workspace を切り替える。
__hz_focus_tab() {
  emulate -L zsh
  local ws=$1 tab=$2 cur
  if __hz_is_app; then
    [[ -n $ws ]] && __hz_app_do space.select --id "$ws" >/dev/null
    __hz_app_do tab.select --id "$tab" >/dev/null
    return
  fi
  if [[ -n $ws ]]; then
    cur=$(__hz_workspace_id) || cur=""
    [[ $ws != "$cur" ]] && herdr workspace focus "$ws" >/dev/null
  fi
  herdr tab focus "$tab" >/dev/null
}

# __hz_close_tab <tab_id>
__hz_close_tab() {
  emulate -L zsh
  if __hz_is_app; then
    # 確認ダイアログを出させない（スクリプトからは応答できない）
    __hz_app_do tab.close --id "$1" --confirmed true >/dev/null
    return
  fi
  herdr tab close "$1" >/dev/null
}

# __hz_create_tab <workspace_id> <label> <cwd> → "<tab_id>\t<pane_id>"（最初のペイン）。
# フォーカスは移さない。移すのは呼び出し側が準備を終えてから。
__hz_create_tab() {
  emulate -L zsh
  local ws=$1 label=$2 cwd=$3 created tab pane term
  if __hz_is_app; then
    created=$(__hz_app_do tab.new --name "$label" --space "$ws" --folder "$cwd" --focus false) || return 1
    IFS=$'\t' read -r tab term < <(print -r -- "$created" | jq -r '[.tab // "", .terminal // ""] | @tsv')
    [[ -n $tab && -n $term ]] || return 1
    # tab.new はペインの id を返さないので一覧から引く。一覧への反映が遅れても
    # 名前付きのタブだけが残らないよう、少し待ってから諦める
    integer i
    for (( i = 0; i < 10; i++ )); do
      pane=$(__hz_app_lookup terminal "$term" pane)
      [[ -n $pane ]] && break
      sleep 0.2
    done
  else
    created=$(herdr tab create --workspace "$ws" --label "$label" --cwd "$cwd" --no-focus) || return 1
    tab=$(print -r -- "$created" | jq -r '.result.tab.tab_id // empty')
    pane=$(print -r -- "$created" | jq -r '.result.root_pane.pane_id // empty')
  fi
  [[ -n $tab && -n $pane ]] || return 1
  print -r -- "$tab"$'\t'"$pane"
}

# __hz_split_pane <pane_id> <right|down> <cwd> → 新しいペインの id。
# TUI は比率 0.5 を渡して半分に割る。app の pane.split は比率を取らない。
__hz_split_pane() {
  emulate -L zsh
  local pane=$1 direction=$2 cwd=$3 out argv
  if __hz_is_app; then
    # app の pane.split には cwd の引数が無く、割ったペインの cwd を引き継ぐ。
    # 起動するコマンドで cd してから、ログインシェルに置き換える。
    argv=$(jq -cn --arg d "$cwd" \
             '["/bin/zsh", "-c", "cd -- \"$1\" && exec \"${SHELL:-/bin/zsh}\" -l", "_", $d]') || return 1
    out=$(__hz_app_do pane.split --direction "$direction" --pane "$pane" --argv "$argv") || return 1
    print -r -- "$out" | jq -er '.pane' 2>/dev/null
    return
  fi
  herdr pane split "$pane" --direction "$direction" --ratio 0.5 --cwd "$cwd" --no-focus \
    | jq -er '.result.pane.pane_id' 2>/dev/null
}

# __hz_rename_pane <pane_id> <name>
__hz_rename_pane() {
  emulate -L zsh
  if __hz_is_app; then
    __hz_app_do pane.rename --pane "$1" --name "$2" >/dev/null
    return
  fi
  herdr pane rename "$1" "$2" >/dev/null
}

# __hz_start_claude <label> <pane_id> [<claude の引数>...] : ペインで claude を起動する。
# TUI の `agent start` は「入力可能になるまで」待つので、claude が初回の信頼確認ダイアログ
# （新しいディレクトリで出る）で止まると起動済みでも非 0 を返す。その場合は agent 検出で
# 起動成功とみなす。ペインの shell 起動中（agent_pane_busy）は数回リトライ。
# app には agent start が無いので、ペインのシェルにコマンドを打ち込み、claude が状態を
# 報告し始めるのを待つ。
__hz_start_claude() {
  emulate -L zsh
  local label=$1 pane=$2; shift 2
  local -a agent_args
  integer attempt
  if __hz_is_app; then
    local term cmd=claude
    (( $# )) && cmd+=" ${(j: :)${(q)@}}"
    term=$(__hz_app_terminal_of "$pane")
    [[ -n $term ]] || return 1
    hc send "$term" "$cmd" >/dev/null 2>&1 || return 1
    # 信頼確認ダイアログのあいだ claude は状態を報告しないので、前面のプロセス名でも判定する
    __hz_app_wait "$term" 20000 '.status.app == "claude-code" or .foreground.name == "claude"'
    return
  fi
  (( $# )) && agent_args=(-- "$@")
  for (( attempt = 0; attempt < 10; attempt++ )); do
    herdr agent start "$label" --kind claude --pane "$pane" "${agent_args[@]}" >/dev/null 2>&1 \
      && return 0
    [[ $(herdr agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent // empty') == claude ]] \
      && return 0
    sleep 0.5
  done
  return 1
}

# __hz_prompt_agent <label> <pane_id> <text> : claude が入力待ち（信頼確認を抜けた状態）に
# なってから text を送る。待つ上限は HELLO_RUN_READY_TIMEOUT（ミリ秒）。
__hz_prompt_agent() {
  emulate -L zsh
  local label=$1 pane=$2 text=$3
  local timeout_ms=${HELLO_RUN_READY_TIMEOUT:-120000}
  if __hz_is_app; then
    local term
    term=$(__hz_app_terminal_of "$pane")
    [[ -n $term ]] || return 1
    # hc wait は blocked（信頼確認）でも抜けるので、idle になるまで自分で見る
    __hz_app_wait "$term" "$timeout_ms" '.status.state == "idle"' || return 1
    hc send "$term" "$text" >/dev/null 2>&1
    return
  fi
  herdr agent wait "$label" --until idle --timeout "$timeout_ms" >/dev/null 2>&1 \
    || return 1
  herdr agent prompt "$label" "$text" >/dev/null 2>&1
}
