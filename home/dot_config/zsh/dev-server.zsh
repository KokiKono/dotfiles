# dev-server: worktree ごとに dev サーバーを立てる（herdr のタブ1つ + アプリごとの pane）。
# 依存: herdr(HERDR_ENV=1), jq, lsof, curl。アプリを選ばせるときだけ fzf。
#
#   <root>/.sessions/issue-<N>/<repo>  で叩くと label `dev-issue-<N>` のタブに pane が並ぶ
#
# worktree ごとにタブを分けるので、同じアプリを別ブランチで同時に動かせる。そのために
# ポートは base から空きを探して **起動コマンドの {{port}} に注入する**（package.json の
# script には --port が焼かれていて上書きできないため、設定には展開済みコマンドを書く）。
#
# 起動コマンド・ポート・ready 行の表は業務リポジトリ固有なので
# ~/.config/dev-server/<repo>.json（chezmoi 管理外）に置く。雛形は同ディレクトリの
# apps.example.json。このリポジトリは PUBLIC なので実データは持たない。
#
# NOTE: zsh では `path` は $PATH に連動する特殊配列。local 変数名には使わない。

source "${0:A:h}/herdr-lib.zsh"

DEV_SERVER_CONFIG_DIR="${DEV_SERVER_CONFIG_DIR:-$HOME/.config/dev-server}"
DEV_SERVER_PORT_SCAN="${DEV_SERVER_PORT_SCAN:-50}"
DEV_SERVER_STOP_WAIT="${DEV_SERVER_STOP_WAIT:-15}"
DEV_SERVER_HTTP_WAIT="${DEV_SERVER_HTTP_WAIT:-30}"

__ds_err() { print -r -- "dev-server: $*" >&2; }

# ---------------------------------------------------------------------------
# 文脈（どの worktree の、どのリポジトリか）
# ---------------------------------------------------------------------------

# __ds_context → "<repo>\t<toplevel>\t<session>\t<label>"
# session は worktree の親。hello-run の配置（<root>/.sessions/issue-<N>/<repo>）なら
# label は dev-issue-<N>。そうでない普通のチェックアウトでは dev-<repo> にする。
# HELLO_RUN_ROOT には依存しない（パスの形だけで決める）。
__ds_context() {
  emulate -L zsh
  local top repo parent label
  top=$(git rev-parse --show-toplevel 2>/dev/null) || {
    __ds_err "git リポジトリの中で実行してください"
    return 1
  }
  repo=${top:t}
  parent=${top:h}
  if [[ ${parent:t} == issue-<-> && ${parent:h:t} == .sessions ]]; then
    label="dev-${parent:t}"
  else
    label="dev-${repo}"
    parent=$top
  fi
  print -r -- "$repo"$'\t'"$top"$'\t'"$parent"$'\t'"$label"
}

__ds_config_file() { print -r -- "${DEV_SERVER_CONFIG_DIR}/${1}.json" }

# __ds_require_config <repo> : 設定ファイルのパスを出す。無ければ案内して 2 を返す。
__ds_require_config() {
  emulate -L zsh
  local file; file=$(__ds_config_file "$1")
  if [[ ! -f $file ]]; then
    __ds_err "設定がありません: $file"
    __ds_err "雛形: ${DEV_SERVER_CONFIG_DIR}/apps.example.json をコピーして、アプリごとに"
    __ds_err "name / cmd（{{port}} を含む展開済みコマンド）/ base_port / ready_regex / url を書いてください"
    return 2
  fi
  jq -e . "$file" >/dev/null 2>&1 || { __ds_err "JSON として読めません: $file"; return 2; }
  print -r -- "$file"
}

__ds_app_names() {
  emulate -L zsh
  jq -r '.apps[]?.name // empty' "$1"
}

# __ds_app <config> <name> → そのアプリの JSON（無ければ 1）
__ds_app() {
  emulate -L zsh
  jq -e --arg n "$2" 'first(.apps[]? | select(.name == $n))' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ポート
# ---------------------------------------------------------------------------

# __ds_port_owner <port> : LISTEN しているプロセスの cwd を出す。
# 空いていれば 1 を返す（cwd が取れないときは空文字で 0 を返す = 使用中・持ち主不明）。
__ds_port_owner() {
  emulate -L zsh
  local pid
  pid=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -1)
  [[ -n $pid ]] || return 1
  lsof -p "$pid" -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
  return 0
}

__ds_under() {
  emulate -L zsh
  local dir=$1 target=$2
  [[ -n $dir && -n $target ]] || return 1
  [[ $target == $dir || $target == $dir/* ]]
}

# __ds_pick_port <base> <fixed:0|1> <session> [<preferred>] → "ok\t<port>" / "conflict\t<cwd>" / "exhausted\t<range>"
# 空きポートを出す。自分（session 配下）が握っているポートは「空き」扱い（この後落とすので）。
# fixed のアプリ（Metro / Storybook / プロキシ配下など）は base から動かせないので、
# 別 worktree が握っていたら**起動せずに**持ち主を添えて 3 を返す。別ブランチのサーバーを
# 自分のものだと思って確認してしまうのが、ここで一番避けたい事故。
__ds_pick_port() {
  emulate -L zsh
  local base=$1 fixed=$2 session=$3 preferred=${4:-}
  local owner p
  local -a candidates

  if [[ -n $preferred ]]; then
    if ! owner=$(__ds_port_owner "$preferred"); then
      print -r -- "ok"$'\t'"$preferred"; return 0
    fi
    if __ds_under "$session" "$owner"; then print -r -- "ok"$'\t'"$preferred"; return 0; fi
  fi

  if (( fixed )); then
    candidates=($base)
  else
    candidates=({$base..$((base + DEV_SERVER_PORT_SCAN))})
  fi

  for p in $candidates; do
    if ! owner=$(__ds_port_owner "$p"); then
      print -r -- "ok"$'\t'"$p"; return 0
    fi
    # 自分の worktree が握っていても、preferred でない限り**別のアプリ**なので避ける。
    # 固定ポートだけは逃げ場が無いので、持ち主が自分なら落として取り直す。
    if (( fixed )); then
      __ds_under "$session" "$owner" && { print -r -- "ok"$'\t'"$p"; return 0 }
      print -r -- "conflict"$'\t'"${owner:-不明なプロセス}"; return 3
    fi
  done
  print -r -- "exhausted"$'\t'"$base..$((base + DEV_SERVER_PORT_SCAN))"
  return 4
}

# __ds_wait_port_free <port> : 解放されるまで待つ。駄目なら kill → kill -9。
__ds_wait_port_free() {
  emulate -L zsh
  local port=$1 pid
  integer i
  for (( i = 0; i < DEV_SERVER_STOP_WAIT; i++ )); do
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    [[ -n $pid ]] || return 0
    (( i == 5 )) && kill "$pid" 2>/dev/null
    (( i == 10 )) && kill -9 "$pid" 2>/dev/null
    sleep 1
  done
  [[ -z $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) ]]
}

# ---------------------------------------------------------------------------
# タブと pane
# ---------------------------------------------------------------------------

# __ds_tab <label> <session> <cwd> [<create:0|1>] → "<tab_id>"。
# create が 0 なら、無いときは空文字を返す（list は見るだけなのでタブを増やさない）。
__ds_tab() {
  emulate -L zsh
  local label=$1 session=$2 cwd=$3 create=${4:-1} found ws created tab
  if found=$(__hz_find_tab "$label" "$session"); then
    print -r -- "${found#*$'\t'}"
    return 0
  fi
  (( create )) || { print -r -- ""; return 0 }
  ws=$(__hz_workspace_id) || { __ds_err "workspace を特定できません（herdr 環境か確認）"; return 1; }
  created=$(herdr tab create --workspace "$ws" --label "$label" --cwd "$cwd" --no-focus) || return 1
  tab=$(print -r -- "$created" | jq -r '.result.tab.tab_id')
  [[ -n $tab && $tab != null ]] || return 1
  print -r -- "$tab"
}

# __ds_panes <tab> → "<pane_id>\t<label>" を並び順に
__ds_panes() {
  emulate -L zsh
  herdr pane list 2>/dev/null | jq -r --arg t "$1" \
    '.result.panes[]? | select(.tab_id == $t) | "\(.pane_id)\t\(.label // "")"'
}

# __ds_find_pane <tab> <app> → "<pane_id>\t<port>"。pane の label が唯一の索引。
__ds_find_pane() {
  emulate -L zsh
  local tab=$1 app=$2 line
  for line in ${(f)"$(__ds_panes "$tab")"}; do
    [[ ${line#*$'\t'} == "$app":* ]] || continue
    print -r -- "${line%%$'\t'*}"$'\t'"${${line#*$'\t'}#*:}"
    return 0
  done
  return 1
}

# __ds_claim_pane <tab> <cwd> → アプリ用の pane。label の無い pane（作りたてのタブの
# root pane）があればそれを使い、無ければ最後の pane を割る。
__ds_claim_pane() {
  emulate -L zsh
  local tab=$1 cwd=$2 line last="" direction
  local -a labeled
  for line in ${(f)"$(__ds_panes "$tab")"}; do
    [[ -n $line ]] || continue
    last=${line%%$'\t'*}
    if [[ -z ${line#*$'\t'} ]]; then print -r -- "$last"; return 0; fi
    labeled+=("$last")
  done
  [[ -n $last ]] || { __ds_err "タブ $tab に pane がありません"; return 1 }
  # 同じ方向に続けて割ると読めない幅になるので right / down を交互にする
  (( ${#labeled} % 2 == 1 )) && direction=right || direction=down
  (( ${#labeled} >= 4 )) && __ds_err "pane が ${#labeled} 枚あります。使っていないアプリは stop を検討してください"
  herdr pane split "$last" --direction "$direction" --ratio 0.5 --cwd "$cwd" --no-focus \
    | jq -r '.result.pane.pane_id'
}

# ---------------------------------------------------------------------------
# 起動
# ---------------------------------------------------------------------------

__ds_strip_icase() { print -r -- "${1//'(?i)'/}" }

# __ds_http_ok <url> : 応答があれば 0。リダイレクトでも応答していれば起動している。
__ds_http_ok() {
  emulate -L zsh
  local code
  code=$(curl -sI -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null)
  [[ -n $code && $code != 000 ]]
}

# __ds_start_app <app-json> <tab> <toplevel> <session> → 1 行 JSON（結果）
__ds_start_app() {
  emulate -L zsh
  local aj=$1 tab=$2 top=$3 session=$4
  local name cmd rel base fixed ready url check envs
  local pane="" oldport="" port st="started" detail="" cmdline rx
  integer timeout

  name=$(jq -r '.name' <<<"$aj")
  cmd=$(jq -r '.cmd' <<<"$aj")
  rel=$(jq -r '.cwd // "."' <<<"$aj")
  base=$(jq -r '.base_port // 3000' <<<"$aj")
  fixed=$(jq -r 'if .port_fixed then 1 else 0 end' <<<"$aj")
  ready=$(jq -r '.ready_regex // "ready in|waiting on|started server|listening on"' <<<"$aj")
  url=$(jq -r '.url // ""' <<<"$aj")
  check=$(jq -r 'if (.check_http // true) then 1 else 0 end' <<<"$aj")
  envs=$(jq -r '.env // {} | to_entries | map("\(.key)=\(.value|tostring|@sh)") | join(" ")' <<<"$aj")
  timeout=$(jq -r '.ready_timeout_ms // 180000' <<<"$aj")

  local found
  if found=$(__ds_find_pane "$tab" "$name"); then
    pane=${found%%$'\t'*}; oldport=${found#*$'\t'}; st=restarted
  fi

  local picked
  picked=$(__ds_pick_port "$base" "$fixed" "$session" "$oldport")
  if [[ ${picked%%$'\t'*} != ok ]]; then
    # 別 worktree が固定ポートを握っている / 空きが無い。kill も別ポート起動もしない。
    __ds_result "$name" "" "" "$pane" conflict "ポート $base を使えません: ${picked#*$'\t'}"
    return 1
  fi
  port=${picked#*$'\t'}

  if [[ -n $pane ]]; then
    # 同じ worktree の既存プロセスは落としてから同じ pane で立て直す。
    # pane を作り直すとレイアウトと label（唯一の索引）が失われる。
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
    __ds_wait_port_free "$oldport" || __ds_err "$name: ポート $oldport を解放できませんでした"
  else
    pane=$(__ds_claim_pane "$tab" "${top}/${rel}") || {
      __ds_result "$name" "$port" "" "" failed "pane を用意できませんでした"
      return 1
    }
  fi
  herdr pane rename "$pane" "${name}:${port}" >/dev/null 2>&1

  cmdline=${cmd//\{\{port\}\}/$port}
  [[ -n $envs ]] && cmdline="$envs $cmdline"
  url=${url//\{\{port\}\}/$port}

  herdr pane run "$pane" "$cmdline" >/dev/null || {
    __ds_result "$name" "$port" "$url" "$pane" failed "pane run に失敗しました"
    return 1
  }

  # 成功と失敗の両方を1つの正規表現で待つ。成功語だけ待つと、落ちたときに
  # タイムアウトまで無言で待つことになり、ユーザーからは固まって見える。
  local fail; fail=$(jq -r '.failure_regex // ""' <<<"$aj")
  [[ -n $fail ]] || fail='eaddrinuse|address already in use|command not found|error:'
  rx="(?i)$(__ds_strip_icase "$ready")|$(__ds_strip_icase "$fail")"
  herdr pane wait-output "$pane" --regex "$rx" --timeout "$timeout" >/dev/null 2>&1 \
    || detail="ready 行が ${timeout}ms 以内に出ませんでした"

  # wait-output のマッチは ready の証明にならない（Expo は Web より先に Metro の行を出す）。
  if (( check )) && [[ -n $url ]]; then
    integer i
    for (( i = 0; i < DEV_SERVER_HTTP_WAIT; i++ )); do
      __ds_http_ok "$url" && { detail=""; break }
      sleep 1
    done
    if ! __ds_http_ok "$url"; then
      __ds_result "$name" "$port" "$url" "$pane" failed \
        "${detail:-HTTP 応答がありません}（herdr pane read $pane でログを確認）"
      return 1
    fi
  fi

  [[ -n $detail ]] && st=failed
  __ds_result "$name" "$port" "$url" "$pane" "$st" "$detail"
}

# __ds_result <name> <port> <url> <pane> <status> <detail>
__ds_result() {
  emulate -L zsh
  jq -cn --arg n "$1" --arg p "$2" --arg u "$3" --arg pane "$4" --arg s "$5" --arg d "$6" \
    '{name:$n, port:(if $p == "" then null else ($p|tonumber) end), url:$u, pane:$pane, status:$s}
     + (if $d == "" then {} else {detail:$d} end)'
}

__ds_status_label() {
  case $1 in
    started)   print -r -- "起動" ;;
    restarted) print -r -- "再起動" ;;
    conflict)  print -r -- "衝突" ;;
    failed)    print -r -- "失敗" ;;
    *)         print -r -- "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# アプリの選択
# ---------------------------------------------------------------------------

# __ds_pick <config> <tab> <session> : fzf で複数選ぶ。選択を改行区切りで出す。
# 印は ● ここで起動中 / ○ 別の場所が base ポートを使用中 / ・ なし。
__ds_pick() {
  emulate -L zsh
  local config=$1 tab=$2 session=$3 name base mark note owner line
  local -a rows
  for name in ${(f)"$(__ds_app_names "$config")"}; do
    base=$(jq -r --arg n "$name" 'first(.apps[]? | select(.name==$n)) | .base_port // 3000' "$config")
    mark="・"; note=""
    if line=$(__ds_find_pane "$tab" "$name"); then
      mark="●"; note="ここで ${line#*$'\t'} で起動中"
    elif owner=$(__ds_port_owner "$base"); then
      if __ds_under "$session" "$owner"; then
        mark="●"; note="ここで起動中"
      else
        mark="○"; note="${owner:t} が使用中"
      fi
    fi
    rows+=("${name}"$'\t'"$(printf '%s %-20s %-6s %s' "$mark" "$name" "$base" "$note")")
  done
  (( ${#rows} )) || { __ds_err "設定にアプリがありません"; return 1; }
  print -rl -- $rows \
    | fzf --multi --ansi --delimiter=$'\t' --with-nth=2 \
          --height=60% --reverse --prompt='dev-server> ' \
          --header='Tab で複数選択 / Enter で起動' \
    | cut -f1
}

# ---------------------------------------------------------------------------
# サブコマンド
# ---------------------------------------------------------------------------

__ds_usage() {
  print -r -- 'usage: dev-server [start] [app...] [--focus] [--json]'
  print -r -- '       dev-server list [--json]'
  print -r -- '       dev-server stop [app...] [--close] [--json]'
  print -r -- '       dev-server restart <app>... [--json]'
}

__ds_cmd_list() {
  emulate -L zsh
  local config=$1 tab=$2 session=$3 json=$4 name base port owner line
  local -a out
  for name in ${(f)"$(__ds_app_names "$config")"}; do
    base=$(jq -r --arg n "$name" 'first(.apps[]? | select(.name==$n)) | .base_port // 3000' "$config")
    if line=$(__ds_find_pane "$tab" "$name"); then
      port=${line#*$'\t'}
      out+=("$(__ds_result "$name" "$port" "http://localhost:${port}" "${line%%$'\t'*}" running "")")
    elif owner=$(__ds_port_owner "$base"); then
      __ds_under "$session" "$owner" \
        && out+=("$(__ds_result "$name" "$base" "" "" running "")") \
        || out+=("$(__ds_result "$name" "$base" "" "" elsewhere "${owner}")")
    else
      out+=("$(__ds_result "$name" "" "" "" stopped "")")
    fi
  done
  if (( json )); then
    print -rl -- $out | jq -cs '{ok:true, apps:.}'
  else
    print -rl -- $out | jq -r '[.name, (.port // "-" | tostring), .status, (.url // ""), (.detail // "")] | @tsv' \
      | column -t -s $'\t'
  fi
}

__ds_cmd_stop() {
  emulate -L zsh
  local tab=$1 close=$2 json=$3; shift 3
  local name line pane port
  local -a out
  integer rc=0
  for name in "$@"; do
    if ! line=$(__ds_find_pane "$tab" "$name"); then
      out+=("$(__ds_result "$name" "" "" "" stopped "起動していません")")
      continue
    fi
    pane=${line%%$'\t'*}; port=${line#*$'\t'}
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
    if __ds_wait_port_free "$port"; then
      (( close )) && herdr pane close "$pane" >/dev/null 2>&1
      out+=("$(__ds_result "$name" "$port" "" "$pane" stopped "")")
    else
      out+=("$(__ds_result "$name" "$port" "" "$pane" failed "ポート $port が解放されません")")
      rc=1
    fi
  done
  if (( json )); then
    print -rl -- $out | jq -cs --argjson ok $(( rc == 0 )) '{ok:($ok==1), apps:.}'
  else
    print -rl -- $out | jq -r '"\(.name) \(.status) \(.detail // "")"'
  fi
  return $rc
}

dev-server() {
  emulate -L zsh
  setopt local_options no_monitor no_notify

  local sub=start json=0 focus=0 close=0
  local -a apps
  case ${1:-} in
    start|list|stop|restart) sub=$1; shift ;;
    -h|--help) __ds_usage; return 0 ;;
  esac
  while (( $# )); do
    case $1 in
      --json)  json=1 ;;
      --focus) focus=1 ;;
      --close) close=1 ;;
      -h|--help) __ds_usage; return 0 ;;
      -*) __ds_err "不明なオプション: $1"; __ds_usage >&2; return 2 ;;
      *) apps+=("$1") ;;
    esac
    shift
  done

  [[ ${HERDR_ENV:-} == 1 ]] || {
    __ds_err "herdr の外なので起動先の pane を用意できません（HERDR_ENV=1 が前提）"
    return 2
  }
  local c
  for c in herdr jq lsof curl; do
    command -v "$c" >/dev/null 2>&1 || { __ds_err "$c が必要です"; return 2 }
  done

  local ctx repo top session label config tab
  ctx=$(__ds_context) || return 1
  local -a ctxf; ctxf=("${(@ps:\t:)ctx}")
  repo=$ctxf[1]; top=$ctxf[2]; session=$ctxf[3]; label=$ctxf[4]
  config=$(__ds_require_config "$repo") || return $?

  if [[ $sub == list ]]; then
    tab=$(__ds_tab "$label" "$session" "$top" 0) || return 1
    __ds_cmd_list "$config" "$tab" "$session" "$json"
    return $?
  fi
  tab=$(__ds_tab "$label" "$session" "$top") || return 1

  if (( ! ${#apps} )); then
    [[ $sub == start ]] || { __ds_err "$sub にはアプリ名が必要です"; return 2 }
    command -v fzf >/dev/null 2>&1 || { __ds_err "アプリ名を指定するか fzf を入れてください"; return 2 }
    apps=(${(f)"$(__ds_pick "$config" "$tab" "$session")"})
    (( ${#apps} )) || { __ds_err "選択されませんでした"; return 0 }
  fi

  local a
  for a in $apps; do
    __ds_app "$config" "$a" >/dev/null || { __ds_err "設定に無いアプリです: $a"; return 2 }
  done

  if [[ $sub == stop ]]; then
    __ds_cmd_stop "$tab" "$close" "$json" $apps
    return $?
  fi

  # 複数アプリは直列に立てる。並列だと空きポートの判定が互いに競合する。
  local -a results
  local aj r
  integer rc=0
  for a in $apps; do
    aj=$(__ds_app "$config" "$a")
    r=$(__ds_start_app "$aj" "$tab" "$top" "$session") || rc=1
    results+=("$r")
    (( json )) || print -r -- "$(jq -r --arg l "$(__ds_status_label "$(jq -r .status <<<"$r")")" \
        '"\($l) \(.name) \(.port // "-") \(.url // "") \(.detail // "")"' <<<"$r")"
  done

  (( focus )) && herdr tab focus "$tab" >/dev/null 2>&1

  if (( json )); then
    print -rl -- $results | jq -cs --arg l "$label" --arg t "$tab" --argjson ok $(( rc == 0 )) \
      '{ok:($ok==1), label:$l, tab:$t, apps:.}'
  fi
  return $rc
}
