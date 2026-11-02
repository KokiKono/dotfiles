# hello-debug: hello-run のセッションで、backend と指定した front アプリをまとめて立てる。
# 依存: dev-server.zsh（ポート・pane の label 索引・ready 待ち）, herdr(HERDR_ENV=1), jq, curl。
#
# dev-server は worktree ごとに dev タブを作るが、hello-debug は**タブを作らない**。
# hello-run が作ったセッションのタブ（main / <front> / <backend>）に pane を足して、
# 作業しているシェルの隣でサーバーのログが流れるようにする:
#
#   main | <front>   | <app1> / <app2> ...   ← front の pane の右に縦に積む
#        | <backend> | backend               ← backend の pane の右
#
# pane は label（`<name>:<port|host>`）で探すので、2 回目以降は同じ pane を使い回す。
# 動いているものは触らない（--restart で立て直す）。
#
# backend の立て方（worktree 用の .env を作る、共有のリバースプロキシを起こす、コンテナを
# 常駐させる等）は業務リポジトリ固有なので ~/.config/hello-debug/config.json（chezmoi 管理外）
# に置く。雛形は同ディレクトリの config.example.json。front のアプリ表は dev-server の
# ~/.config/dev-server/<front>.json をそのまま使う。
#
# NOTE: zsh では `path` は $PATH に連動する特殊配列。local 変数名には使わない。

source "${0:A:h}/dev-server.zsh"

HELLO_DEBUG_CONFIG="${HELLO_DEBUG_CONFIG:-$HOME/.config/hello-debug/config.json}"
HELLO_DEBUG_POLL="${HELLO_DEBUG_POLL:-2}"

__hd_err() { print -r -- "hello-debug: $*" >&2; }

__hd_usage() {
  print -r -- 'usage: hello-debug [start] [app...] [--no-backend] [--restart] [--json]'
  print -r -- '       hello-debug list [--json]'
  print -r -- '       hello-debug stop [backend|app...] [--json]'
  print -r -- '  app を省くと fzf で選ぶ（端末でないときは backend だけ）'
}

# __hd_session <dir> → hello-run のセッションディレクトリ（.sessions 直下の 1 階層）
__hd_session() {
  emulate -L zsh
  # :A でシンボリックリンクを解決すると、herdr が持つ pane の cwd（論理パス）と食い違う
  local dir=${1:a} rest
  [[ $dir == */.sessions/* ]] || return 1
  rest=${dir#*/.sessions/}
  print -r -- "${dir%%/.sessions/*}/.sessions/${rest%%/*}"
}

# __hd_tab <session> → セッションのタブ。タブは作らない。
# 呼び出し元の pane のタブがセッションのものならそれを使う（hello-run のタブ以外で
# 作業していても、いま見ているタブに出す）。そうでなければ label で探す。
__hd_tab() {
  emulate -L zsh
  local session=$1 found
  if [[ -n ${HERDR_TAB_ID:-} ]] && __hz_tab_has_cwd_under "$HERDR_TAB_ID" "$session"; then
    print -r -- "$HERDR_TAB_ID"
    return 0
  fi
  found=$(__hz_find_tab "${session:t}" "$session") || return 1
  print -r -- "${found#*$'\t'}"
}

# __hd_pane_by_label <tab> <label> → label が完全一致する pane（hello-run が repo 名で付ける）
__hd_pane_by_label() {
  emulate -L zsh
  local line
  for line in ${(f)"$(__ds_panes "$1")"}; do
    [[ ${line#*$'\t'} == "$2" ]] && { print -r -- "${line%%$'\t'*}"; return 0 }
  done
  return 1
}

# __hd_in <dir> <shell> : dir で shell を評価して stdout を出す（設定の *_cmd 用）
__hd_in() {
  emulate -L zsh
  [[ -d $1 ]] || return 1
  ( cd "$1" && eval "$2" ) 2>/dev/null
}

__hd_status_label() {
  case $1 in
    running) print -r -- "起動済み" ;;
    stopped) print -r -- "停止" ;;
    *)       __ds_status_label "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# backend
# ---------------------------------------------------------------------------

# __hd_backend_host <backend-json> <worktree> → host_cmd の結果（取れなければ 1）
__hd_backend_host() {
  emulate -L zsh
  local hcmd host
  hcmd=$(jq -r '.host_cmd // ""' <<<"$1")
  [[ -n $hcmd ]] || return 1
  host=$(__hd_in "$2" "$hcmd") || return 1
  [[ -n $host ]] || return 1
  print -r -- "$host"
}

# __hd_backend_ok <url> : backend 自身が応答していれば 0。
# リバースプロキシ越しだと、経路が無ければ 404、繋ぎ先が落ちていれば 502〜504 が返る。
# dev-server の __ds_http_ok（応答があれば可）ではこれを起動済みと取り違える。
# 一方 500 はアプリが返したもの（未適用のマイグレーション等）なので起動済みとし、
# 画面で原因を見せる。よって url には 404 にならないパスを書く。
__hd_backend_ok() {
  emulate -L zsh
  local code
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null)
  [[ -n $code && $code != (000|404|502|503|504) ]]
}

# __hd_backend_url <backend-json> <host> → url（{{host}} を展開）
__hd_backend_url() {
  emulate -L zsh
  local url
  url=$(jq -r '.url // ""' <<<"$1")
  print -r -- "${url//\{\{host\}\}/$2}"
}

# __hd_start_backend <backend-json> <tab> <session> <restart:0|1> → 1 行 JSON
# コンテナで常駐させる backend は、pane を閉じても止まらない。pane はログを流す窓であり、
# 生死は url への HTTP 応答で判定する（pane の出力だけでは、既に動いていたのか今
# 立ったのかを区別できない）。
__hd_start_backend() {
  emulate -L zsh
  local bj=$1 tab=$2 session=$3 restart=$4
  local name repo wt pane="" host="" url="" st=started anchor setup cmd stopc fail cmdline out
  integer timeout waited=0 seen=0

  name=$(jq -r '.name // "backend"' <<<"$bj")
  repo=$(jq -r '.repo // ""' <<<"$bj")
  wt="$session/$repo"
  [[ -n $repo && -d $wt ]] || {
    __ds_result "$name" "" "" "" failed "worktree がありません: $wt"
    return 1
  }

  local found
  if found=$(__ds_find_pane "$tab" "$name"); then
    pane=${found%%$'\t'*}
    st=restarted
    if (( ! restart )) && host=$(__hd_backend_host "$bj" "$wt"); then
      url=$(__hd_backend_url "$bj" "$host")
      if [[ -n $url ]] && __hd_backend_ok "$url"; then
        __ds_result "$name" "" "$url" "$pane" running ""
        return 0
      fi
    fi
    # ログの追従（docker logs -f 等）を抜けてから打ち直す
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
  else
    anchor=$(__hd_pane_by_label "$tab" "$repo") || anchor=""
    pane=$(__ds_claim_pane "$tab" "$wt" "$anchor" right) || pane=""
    [[ -n $pane && $pane != null ]] || {
      __ds_result "$name" "" "" "" failed "pane を用意できませんでした"
      return 1
    }
  fi
  herdr pane rename "$pane" "${name}:starting" >/dev/null 2>&1

  setup=$(jq -r '(.setup // []) | join(" && ")' <<<"$bj")
  cmd=$(jq -r '.cmd // ""' <<<"$bj")
  stopc=$(jq -r '.stop_cmd // ""' <<<"$bj")
  cmdline=$cmd
  [[ -n $setup ]] && cmdline="$setup && $cmdline"
  # 立て直しは止めてからにする。止める側の失敗（既に止まっている）では先に進める。
  (( restart )) && [[ -n $stopc ]] && cmdline="{ $stopc; } ; $cmdline"
  # 失敗の判定は今回の出力だけで行う。pane には前回の失敗や、打ち込んだコマンド
  # そのもの（失敗時に出す文言を含みうる）が残っている。マーカーは printf の書式で
  # 組み立て、打ち込んだ行の文字列とは一致しないようにする。
  local marker="hello-debug-run-${RANDOM}${RANDOM}"
  cmdline="printf 'hello-debug-run-%s\\n' ${marker#hello-debug-run-}; $cmdline"
  herdr pane run "$pane" "$cmdline" >/dev/null || {
    __ds_result "$name" "" "" "$pane" failed "pane run に失敗しました"
    return 1
  }

  timeout=$(jq -r '(.ready_timeout_ms // 300000) / 1000 | floor' <<<"$bj")
  fail=$(jq -r '.failure_regex // "command not found|no such container|cannot connect to the docker daemon"' <<<"$bj")
  while (( waited < timeout )); do
    # host は setup が作るファイル（.env 等）から引くことがあるので、毎回取り直す
    if host=$(__hd_backend_host "$bj" "$wt"); then
      url=$(__hd_backend_url "$bj" "$host")
      if [[ -n $url ]] && __hd_backend_ok "$url"; then
        herdr pane rename "$pane" "${name}:${host}" >/dev/null 2>&1
        __ds_result "$name" "" "$url" "$pane" "$st" ""
        return 0
      fi
    fi
    out=$(herdr pane read "$pane" --source recent-unwrapped --lines 80 2>/dev/null)
    # 一度マーカーを見たら、それが読み取り範囲から流れ出た後は範囲全体が今回の出力。
    # マーカー以降だけを見続けると、ログの多い setup（DB の用意等）の失敗を見逃して
    # タイムアウトまで黙って待つことになる。
    if print -r -- "$out" | grep -qx -- "$marker"; then
      seen=1
      out=$(print -r -- "$out" | sed -n "/^${marker}\$/,\$p")
    elif (( ! seen )); then
      out=""
    fi
    if [[ -n $fail && -n $out ]] && print -r -- "$out" | grep -qiE -- "$fail"; then
      __ds_result "$name" "" "$url" "$pane" failed \
        "$(print -r -- "$out" | grep -iE -- "$fail" | tail -n 1)（herdr pane read $pane でログを確認）"
      return 1
    fi
    sleep "$HELLO_DEBUG_POLL"
    (( waited += HELLO_DEBUG_POLL ))
  done
  __ds_result "$name" "" "$url" "$pane" failed \
    "${timeout} 秒以内に ${url:-url} が応答しませんでした（herdr pane read $pane でログを確認）"
  return 1
}

__hd_stop_backend() {
  emulate -L zsh
  local bj=$1 tab=$2 session=$3 name repo found pane stopc
  name=$(jq -r '.name // "backend"' <<<"$bj")
  repo=$(jq -r '.repo // ""' <<<"$bj")
  stopc=$(jq -r '.stop_cmd // ""' <<<"$bj")
  found=$(__ds_find_pane "$tab" "$name") || {
    __ds_result "$name" "" "" "" stopped "起動していません"
    return 0
  }
  pane=${found%%$'\t'*}
  herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
  if [[ -n $stopc ]] && ! __hd_in "$session/$repo" "$stopc" >/dev/null; then
    __ds_result "$name" "" "" "$pane" failed "stop_cmd が失敗しました: $stopc"
    return 1
  fi
  herdr pane close "$pane" >/dev/null 2>&1
  __ds_result "$name" "" "" "$pane" stopped ""
}

# ---------------------------------------------------------------------------
# front
# ---------------------------------------------------------------------------

# __hd_app_url <app-json> <port>
__hd_app_url() {
  emulate -L zsh
  local url
  url=$(jq -r '.url // ""' <<<"$1")
  print -r -- "${url//\{\{port\}\}/$2}"
}

# __hd_front_anchor <tab> <config> <front-repo> → "<pane>\t<direction>"
# 既にあるアプリの pane の下に積む。無ければ front の pane の右に出す。
__hd_front_anchor() {
  emulate -L zsh
  local tab=$1 config=$2 repo=$3 line label last="" pane
  local -a names
  names=(${(f)"$(__ds_app_names "$config")"})
  for line in ${(f)"$(__ds_panes "$tab")"}; do
    label=${line#*$'\t'}
    (( ${names[(Ie)${label%%:*}]} )) && [[ $label == *:* ]] && last=${line%%$'\t'*}
  done
  if [[ -n $last ]]; then print -r -- "$last"$'\t'"down"; return 0; fi
  if pane=$(__hd_pane_by_label "$tab" "$repo"); then print -r -- "$pane"$'\t'"right"; return 0; fi
  print -r -- ""$'\t'""
}

# __hd_start_front <config> <app> <tab> <front-worktree> <session> <front-repo> <restart>
__hd_start_front() {
  emulate -L zsh
  local config=$1 app=$2 tab=$3 top=$4 session=$5 repo=$6 restart=$7
  local aj found port url anchor
  aj=$(__ds_app "$config" "$app")
  if (( ! restart )) && found=$(__ds_find_pane "$tab" "$app"); then
    port=${found#*$'\t'}
    url=$(__hd_app_url "$aj" "$port")
    if [[ -n $url ]] && __ds_http_ok "$url"; then
      __ds_result "$app" "$port" "$url" "${found%%$'\t'*}" running ""
      return 0
    fi
  fi
  anchor=$(__hd_front_anchor "$tab" "$config" "$repo")
  __ds_start_app "$aj" "$tab" "$top" "$session" "${anchor%%$'\t'*}" "${anchor#*$'\t'}"
}

__hd_stop_front() {
  emulate -L zsh
  local tab=$1 app=$2 found pane port
  found=$(__ds_find_pane "$tab" "$app") || {
    __ds_result "$app" "" "" "" stopped "起動していません"
    return 0
  }
  pane=${found%%$'\t'*}; port=${found#*$'\t'}
  herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
  if ! __ds_wait_port_free "$port"; then
    __ds_result "$app" "$port" "" "$pane" failed "ポート $port が解放されません"
    return 1
  fi
  herdr pane close "$pane" >/dev/null 2>&1
  __ds_result "$app" "$port" "" "$pane" stopped ""
}

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

__hd_print_line() {
  emulate -L zsh
  print -r -- "$(jq -r --arg l "$(__hd_status_label "$(jq -r .status <<<"$1")")" \
      '"\($l) \(.name) \(.url // "") \(.pane // "") \(.detail // "")"' <<<"$1")"
}

# __hd_notes <backend-json> <host> → notes の各行（{{host}} を展開）
__hd_notes() {
  emulate -L zsh
  local line
  for line in ${(f)"$(jq -r '(.notes // [])[]' <<<"$1")"}; do
    print -r -- "${line//\{\{host\}\}/$2}"
  done
}

# ---------------------------------------------------------------------------
# 本体
# ---------------------------------------------------------------------------

hello-debug() {
  emulate -L zsh
  setopt local_options no_monitor no_notify

  local sub=start json=0 restart=0 backend=1
  local -a targets
  case ${1:-} in
    start|list|stop) sub=$1; shift ;;
    -h|--help) __hd_usage; return 0 ;;
  esac
  while (( $# )); do
    case $1 in
      --json)       json=1 ;;
      --restart)    restart=1 ;;
      --no-backend) backend=0 ;;
      -h|--help)    __hd_usage; return 0 ;;
      -*) __hd_err "不明なオプション: $1"; __hd_usage >&2; return 2 ;;
      *) targets+=("$1") ;;
    esac
    shift
  done

  [[ ${HERDR_ENV:-} == 1 ]] || {
    __hd_err "herdr の外なので pane を用意できません（HERDR_ENV=1 が前提）"
    return 2
  }
  local c
  for c in herdr jq lsof curl; do
    command -v "$c" >/dev/null 2>&1 || { __hd_err "$c が必要です"; return 2 }
  done
  [[ -f $HELLO_DEBUG_CONFIG ]] || {
    __hd_err "設定がありません: $HELLO_DEBUG_CONFIG"
    __hd_err "雛形: ${HELLO_DEBUG_CONFIG:h}/config.example.json"
    return 2
  }
  jq -e . "$HELLO_DEBUG_CONFIG" >/dev/null 2>&1 || { __hd_err "JSON として読めません: $HELLO_DEBUG_CONFIG"; return 2 }

  local session tab bj front_repo front_config
  session=$(__hd_session "$PWD") || {
    __hd_err "hello-run のセッション（<root>/.sessions/<name>/ 配下）で実行してください"
    return 1
  }
  tab=$(__hd_tab "$session") || {
    __hd_err "セッション ${session:t} のタブが見つかりません（hello-debug はタブを作りません）"
    return 1
  }
  bj=$(jq -c '.backend // empty' "$HELLO_DEBUG_CONFIG")
  front_repo=$(jq -r '.front_repo // ""' "$HELLO_DEBUG_CONFIG")
  front_config=""
  [[ -n $front_repo ]] && { front_config=$(__ds_require_config "$front_repo") || return $? }

  local bname=""
  [[ -n $bj ]] && bname=$(jq -r '.name // "backend"' <<<"$bj")

  local -a results apps
  local r t host=""
  integer rc=0

  if [[ $sub == list ]]; then
    local line label
    for line in ${(f)"$(__ds_panes "$tab")"}; do
      label=${line#*$'\t'}
      [[ $label == *:* ]] || continue
      if [[ -n $bname && ${label%%:*} == $bname ]]; then
        host=${label#*:}
        r=$(__ds_result "$bname" "" "$(__hd_backend_url "$bj" "$host")" "${line%%$'\t'*}" running "")
      elif [[ -n $front_config ]] && __ds_app "$front_config" "${label%%:*}" >/dev/null; then
        r=$(__ds_result "${label%%:*}" "${label#*:}" \
              "$(__hd_app_url "$(__ds_app "$front_config" "${label%%:*}")" "${label#*:}")" \
              "${line%%$'\t'*}" running "")
      else
        continue
      fi
      results+=("$r")
    done
    if (( json )); then
      print -rl -- $results | jq -cs --arg t "$tab" '{ok:true, tab:$t, apps:.}'
    else
      for r in $results; do __hd_print_line "$r"; done
    fi
    return 0
  fi

  if [[ $sub == stop ]]; then
    integer all=0
    if (( ! ${#targets} )); then
      all=1
      [[ -n $bname ]] && targets+=("$bname")
      [[ -n $front_config ]] && targets+=(${(f)"$(__ds_app_names "$front_config")"})
    fi
    for t in $targets; do
      # 引数なしの stop は全アプリを舐めるので、pane の無いものは黙って飛ばす
      (( all )) && ! __ds_find_pane "$tab" "$t" >/dev/null && continue
      if [[ -n $bname && $t == $bname ]]; then
        r=$(__hd_stop_backend "$bj" "$tab" "$session") || rc=1
      elif [[ -n $front_config ]] && __ds_app "$front_config" "$t" >/dev/null; then
        r=$(__hd_stop_front "$tab" "$t") || rc=1
      else
        __hd_err "設定に無い名前です: $t"; return 2
      fi
      results+=("$r")
      (( json )) || __hd_print_line "$r"
    done
    (( json )) && print -rl -- $results | jq -cs --arg t "$tab" --argjson ok $(( rc == 0 )) '{ok:($ok==1), tab:$t, apps:.}'
    return $rc
  fi

  # start
  for t in $targets; do
    [[ -n $front_config ]] && __ds_app "$front_config" "$t" >/dev/null \
      || { __hd_err "設定に無いアプリです: $t"; return 2 }
    apps+=("$t")
  done
  if (( ! ${#apps} )) && [[ -n $front_config ]] && (( ! json )) && [[ -t 0 && -t 1 ]] \
      && command -v fzf >/dev/null 2>&1; then
    apps=(${(f)"$(__ds_pick "$front_config" "$tab" "$session")"})
  fi

  # backend を先に立てる。front は backend に繋ぎに行くので、逆だと最初の画面がエラーになる。
  if (( backend )) && [[ -n $bj ]]; then
    r=$(__hd_start_backend "$bj" "$tab" "$session" "$restart") || rc=1
    results+=("$r")
    (( json )) || __hd_print_line "$r"
  fi

  # 作りたての worktree には依存が入っていない。アプリの pane で入れさせると、
  # 複数アプリが同時に同じ node_modules へ書き込むので、ここで 1 回だけ済ませる。
  local fsetup
  fsetup=$(jq -r '(.front_setup // []) | join(" && ")' "$HELLO_DEBUG_CONFIG")
  if (( ${#apps} )) && [[ -n $fsetup ]]; then
    if ! ( cd "$session/$front_repo" && eval "$fsetup" ) >&2; then
      __hd_err "front_setup が失敗しました: $fsetup"
      return 1
    fi
  fi

  # 複数アプリは直列に立てる。並列だと空きポートの判定が互いに競合する。
  for t in $apps; do
    r=$(__hd_start_front "$front_config" "$t" "$tab" "$session/$front_repo" "$session" "$front_repo" "$restart") || rc=1
    results+=("$r")
    (( json )) || __hd_print_line "$r"
  done

  local -a notes
  if [[ -n $bj ]]; then
    host=$(__hd_backend_host "$bj" "$session/$(jq -r '.repo // ""' <<<"$bj")") \
      && notes=(${(f)"$(__hd_notes "$bj" "$host")"})
  fi
  if (( json )); then
    print -rl -- $results | jq -cs --arg t "$tab" --argjson ok $(( rc == 0 )) \
      --argjson notes "$(print -rl -- $notes | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      '{ok:($ok==1), tab:$t, apps:., notes:$notes}'
  elif (( ${#notes} )); then
    print -r -- ""
    print -rl -- $notes
  fi
  return $rc
}
