# hello-run: GitHub issue から作業環境を一発で用意する（worktree + herdr タブ + claude）。
# 依存: herdr(HERDR_ENV=1), wt(worktrunk), gh, jq。slug 推定に claude があれば使う（任意）。
#
# worktree は wt のデフォルト配置（repo の兄弟 `<repo>.<branch>`）ではなく、issue ごとの
# セッションディレクトリ配下にまとめる。claude をその親ディレクトリで起動して全 worktree を
# 横断探索できるようにするため。配置の上書きは `wt --config-set` でこの呼び出し限定に行うので、
# 手で叩く `wt switch` の既存配置には影響しない。
#
#   <root>/.sessions/issue-<N>/        ← claude の cwd（main ペイン）
#   ├── <repo-a>/
#   └── <repo-b>/
#
# NOTE: zsh では `path` は $PATH に連動する特殊配列。local 変数名には使わない（wtpath 等にする）。
#       また同一スコープで同じ名前を二度 local 宣言すると中身が stdout に出るので避ける。

# 対象の org / リポジトリはこのリポジトリが PUBLIC なので既定値を持たせない。
# 実際の値は ~/.pzshrc（chezmoi 管理外。.zshrc がこのファイルより先に source する）に書く:
#
#   HELLO_RUN_ROOT=~/git_clone/github.com/<org>   # リポジトリ群の親ディレクトリ
#   HELLO_RUN_ISSUE_REPO=<org>/<repo>             # issue 番号だけ渡したときの既定リポジトリ
#   HELLO_RUN_REPOS=(<repo-a> <repo-b>)           # worktree を作るリポジトリ（先頭が主）
HELLO_RUN_ROOT="${HELLO_RUN_ROOT:-}"
HELLO_RUN_ISSUE_REPO="${HELLO_RUN_ISSUE_REPO:-}"
HELLO_RUN_SLUG_MODEL="${HELLO_RUN_SLUG_MODEL:-claude-haiku-4-5-20251001}"
typeset -ga HELLO_RUN_REPOS

__hr_err() { print -r -- "hello-run: $*" >&2; }

# ---------------------------------------------------------------------------
# 進捗表示（チェックリスト + スピナー）
#
# 端末なら全ステップを一覧で描き、実行中の行をスピナーで回して、終わったら ✔/✘ に
# 書き換える。カーソル移動は行数を数えた相対移動なので、行が折り返すと表示が崩れる。
# よって $COLUMNS を見て必ず 1 行に収まるよう切り詰める。
# 非 TTY（パイプ・CI）や NO_COLOR ではエスケープを一切出さず、素の行を追記するだけ。
# ---------------------------------------------------------------------------

typeset -ga __HR_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# 表示幅の計算。日本語（かな・漢字・全角約物）は 2 桁、ASCII と、この UI で使う記号
# （スピナー・チェック・罫線・三点リーダ）は 1 桁として数える。後者は Unicode の
# East Asian Ambiguous で、端末によっては 2 桁になりうるが、本モジュールが想定する
# 端末（ambiguous=narrow）では 1 桁。ここを間違えると罫線と桁揃えがずれる。
typeset -g __HR_NARROW='…✔✘○⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏╭╮╰╯─│'

__hr_dwidth() {
  emulate -L zsh
  local s=$1
  integer w=0 i
  for (( i = 1; i <= ${#s}; i++ )); do
    if [[ $s[i] == [[:ascii:]] || $__HR_NARROW == *$s[i]* ]]; then
      (( w += 1 ))
    else
      (( w += 2 ))
    fi
  done
  print -r -- $w
}

# 表示幅 <max> に収まるよう末尾を … に置き換える
__hr_trunc() {
  emulate -L zsh
  local s=$1 out=""
  integer max=$2 w=0 cw i
  (( $(__hr_dwidth "$s") <= max )) && { print -r -- "$s"; return; }
  (( max -= 1 ))   # … の分
  for (( i = 1; i <= ${#s}; i++ )); do
    if [[ $s[i] == [[:ascii:]] || $__HR_NARROW == *$s[i]* ]]; then cw=1; else cw=2; fi
    (( w + cw > max )) && break
    out+=$s[i]
    (( w += cw ))
  done
  print -r -- "${out}…"
}

__hr_ui_init() {
  emulate -L zsh
  typeset -g __HR_UI_TTY=0
  [[ -t 1 && -z ${NO_COLOR:-} ]] && __HR_UI_TTY=1
  if (( __HR_UI_TTY )); then
    typeset -g __HR_C_DIM=$'\e[2m' __HR_C_GRN=$'\e[32m' __HR_C_RED=$'\e[31m' \
               __HR_C_CYN=$'\e[36m' __HR_C_BLD=$'\e[1m' __HR_C_RST=$'\e[0m'
  else
    typeset -g __HR_C_DIM="" __HR_C_GRN="" __HR_C_RED="" \
               __HR_C_CYN="" __HR_C_BLD="" __HR_C_RST=""
  fi

  local title=$1; shift
  typeset -ga __HR_UI_LABELS=("$@")
  typeset -ga __HR_UI_DETAILS=() __HR_UI_STATES=() __HR_UI_LW=()
  typeset -g __HR_UI_N=${#__HR_UI_LABELS} __HR_UI_CUR=0 __HR_UI_FRAME=0 __HR_UI_LABELW=0

  integer i w
  for (( i = 1; i <= __HR_UI_N; i++ )); do
    __HR_UI_DETAILS[i]=""
    __HR_UI_STATES[i]=pending
    w=$(__hr_dwidth "${__HR_UI_LABELS[i]}")
    __HR_UI_LW[i]=$w
    (( w > __HR_UI_LABELW )) && __HR_UI_LABELW=$w
  done

  print -r -- ""
  print -r -- "  ${__HR_C_BLD}${title}${__HR_C_RST}"
  print -r -- ""
  if (( __HR_UI_TTY )); then
    for (( i = 1; i <= __HR_UI_N; i++ )); do
      print -r -- "$(__hr_ui_line $i)"
    done
  fi
}

__hr_ui_line() {
  emulate -L zsh
  integer i=$1
  local state=${__HR_UI_STATES[i]} sym color spaces="" detail=${__HR_UI_DETAILS[i]}
  case $state in
    active)  sym=${__HR_SPIN[ (__HR_UI_FRAME % ${#__HR_SPIN}) + 1 ]}; color=$__HR_C_CYN ;;
    done)    sym='✔'; color=$__HR_C_GRN ;;
    fail)    sym='✘'; color=$__HR_C_RED ;;
    *)       sym='○'; color=$__HR_C_DIM ;;
  esac
  integer pad=$(( __HR_UI_LABELW - __HR_UI_LW[i] )) k
  for (( k = 0; k < pad; k++ )); do spaces+=' '; done
  integer avail=$(( ${COLUMNS:-100} - __HR_UI_LABELW - 8 ))
  (( avail < 8 )) && avail=8
  [[ -n $detail ]] && detail=$(__hr_trunc "$detail" $avail)
  print -rn -- "  ${color}${sym}${__HR_C_RST} ${__HR_UI_LABELS[i]}${spaces}  ${__HR_C_DIM}${detail}${__HR_C_RST}"
}

# 一覧の下にいるカーソルから i 行目まで戻って書き換え、元の位置に戻る
__hr_ui_render() {
  (( __HR_UI_TTY )) || return 0
  integer up=$(( __HR_UI_N - $1 + 1 ))
  printf '\e[%dA\r\e[2K%s\e[%dB\r' $up "$(__hr_ui_line $1)" $up
}

__hr_ui_begin() {
  __HR_UI_CUR=$1
  __HR_UI_STATES[$1]=active
  __hr_ui_render $1
}

__hr_ui_detail() {
  __HR_UI_DETAILS[$__HR_UI_CUR]=$1
  __hr_ui_render $__HR_UI_CUR
}

__hr_ui_done() {
  __HR_UI_STATES[$__HR_UI_CUR]=done
  if (( __HR_UI_TTY )); then
    __hr_ui_render $__HR_UI_CUR
  else
    print -r -- "  [${__HR_UI_CUR}/${__HR_UI_N}] ok ${__HR_UI_LABELS[$__HR_UI_CUR]}${__HR_UI_DETAILS[$__HR_UI_CUR]:+  ${__HR_UI_DETAILS[$__HR_UI_CUR]}}"
  fi
}

# __hr_ui_fail [ログファイル]: 現在行を ✘ にして、下請けの出力を展開する
__hr_ui_fail() {
  __HR_UI_STATES[$__HR_UI_CUR]=fail
  if (( __HR_UI_TTY )); then
    __hr_ui_render $__HR_UI_CUR
  else
    print -r -- "  [${__HR_UI_CUR}/${__HR_UI_N}] NG ${__HR_UI_LABELS[$__HR_UI_CUR]}${__HR_UI_DETAILS[$__HR_UI_CUR]:+  ${__HR_UI_DETAILS[$__HR_UI_CUR]}}"
  fi
  local logfile=${1:-}
  print -r -- ""
  if [[ -n $logfile && -s $logfile ]]; then
    sed 's/^/      /' "$logfile" >&2
    print -r -- ""
  fi
}

# __hr_ui_box <title> <key> <value> ...: 完了サマリ。
# 罫線幅は表示幅ベースなので、中身は ASCII（branch / path / tab id）に限る。
__hr_ui_box() {
  emulate -L zsh
  local title=$1; shift
  local -a keys vals
  local bar="" line
  integer i w inner=0 keyw=0 barw padw
  for (( i = 1; i <= $#; i += 2 )); do
    keys+=("${@[i]}")
    vals+=("${@[i+1]}")
    (( ${#${@[i]}} > keyw )) && keyw=${#${@[i]}}
  done
  # 端末幅をはみ出すと折り返して罫線が崩れるので、値を切り詰める
  integer valmax=$(( ${COLUMNS:-100} - keyw - 10 ))
  (( valmax < 12 )) && valmax=12
  for (( i = 1; i <= ${#keys}; i++ )); do
    vals[i]=$(__hr_trunc "${vals[i]}" $valmax)
    w=$(( keyw + 2 + $(__hr_dwidth "${vals[i]}") ))
    (( w > inner )) && inner=$w
  done
  (( ${#title} + 3 > inner )) && inner=$(( ${#title} + 3 ))
  barw=$(( inner - ${#title} - 1 ))
  (( barw < 1 )) && barw=1
  for (( i = 0; i < barw; i++ )); do bar+='─'; done
  print -r -- ""
  print -r -- "  ${__HR_C_DIM}╭─${__HR_C_RST} ${__HR_C_BLD}${title}${__HR_C_RST} ${__HR_C_DIM}${bar}╮${__HR_C_RST}"
  for (( i = 1; i <= ${#keys}; i++ )); do
    line=$(printf "%-${keyw}s  %s" "${keys[i]}" "${vals[i]}")
    padw=$(( inner - $(__hr_dwidth "$line") ))
    (( padw < 0 )) && padw=0
    printf "  %s│%s %s%${padw}s %s│%s\n" \
      "$__HR_C_DIM" "$__HR_C_RST" "$line" "" "$__HR_C_DIM" "$__HR_C_RST"
  done
  bar=""
  for (( i = 0; i < inner + 2; i++ )); do bar+='─'; done
  print -r -- "  ${__HR_C_DIM}╰${bar}╯${__HR_C_RST}"
}

# __hr_step <結果ファイル> <コマンド...>
# コマンドをバックグラウンドで走らせ、終わるまでスピナーを回す。stdout は結果ファイル、
# stderr はログへ。バックグラウンドは親の変数を書けないので戻り値はファイル経由で受け取る。
# 失敗時のログは $__HR_STEP_LOG に入る。
__hr_step() {
  local out=$1; shift
  typeset -g __HR_STEP_LOG
  __HR_STEP_LOG=$(mktemp) || return 1
  ( "$@" >"$out" 2>"$__HR_STEP_LOG" ) &
  local pid=$!
  if (( __HR_UI_TTY )); then
    while kill -0 $pid 2>/dev/null; do
      (( __HR_UI_FRAME++ ))
      __hr_ui_render $__HR_UI_CUR
      sleep 0.08
    done
  fi
  wait $pid
}

# ---------------------------------------------------------------------------

# __hr_parse_issue <url|number|#number>: `owner/repo \t number` を出す
__hr_parse_issue() {
  emulate -L zsh
  local arg=$1 repo num
  num=$(print -r -- "$arg" | sed -n -E 's#^.*/issues/([0-9]+).*$#\1#p')
  if [[ -n $num ]]; then
    repo=$(print -r -- "$arg" | sed -n -E 's#^.*github\.com/([^/]+)/([^/]+)/issues/.*$#\1/\2#p')
    [[ -n $repo ]] || repo=$HELLO_RUN_ISSUE_REPO
  else
    num=$(print -r -- "$arg" | sed -n -E 's/^#?([0-9]+)$/\1/p')
    [[ -n $num ]] || return 1
    repo=$HELLO_RUN_ISSUE_REPO
  fi
  print -r -- "$repo"$'\t'"$num"
}

# __hr_issue_title <owner/repo> <number>
__hr_issue_title() {
  emulate -L zsh
  gh issue view "$2" --repo "$1" --json title --jq .title 2>/dev/null
}

# __hr_sanitize_slug <text>: ブランチ名に使える kebab-case に正規化する。
# 英数字以外はハイフンに潰し、小文字化して 50 文字で切る。空になったら非 0。
__hr_sanitize_slug() {
  emulate -L zsh
  local out
  out=$(print -r -- "$1" | head -1 | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-' \
          | sed -E 's/-{2,}/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//')
  [[ -n $out ]] || return 1
  print -r -- "$out"
}

# __hr_slugify <title>: haiku に kebab-case の英語 slug を推定させる。
# claude が無い / 失敗 / 空ならば非 0 を返し、呼び出し側は slug 無しにフォールバックする。
__hr_slugify() {
  emulate -L zsh
  local title=$1 out
  command -v claude >/dev/null 2>&1 || return 1
  out=$(print -r -- "$title" | claude -p --model "$HELLO_RUN_SLUG_MODEL" \
    'Convert the GitHub issue title given on stdin into a short English branch slug.
Rules: kebab-case, 3-5 words, lowercase a-z 0-9 and hyphens only, no issue number,
no prefix such as feat/ or fix/. Output the slug only, nothing else.' 2>/dev/null) || return 1
  __hr_sanitize_slug "$out"
}

# __hr_branch_exists <repo-dir> <branch>
__hr_branch_exists() {
  emulate -L zsh
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" && return 0
  git -C "$1" ls-remote --exit-code --heads origin "$2" >/dev/null 2>&1
}

# __hr_default_branch <repo-dir>: origin/HEAD → main/master の順でデフォルトブランチ名を推定
__hr_default_branch() {
  emulate -L zsh
  local ref b
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  [[ -n $ref ]] && { print -r -- "${ref#origin/}"; return 0; }
  for b in main master; do
    git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$b" && { print -r -- "$b"; return 0; }
  done
  return 1
}

# __hr_make_worktree <repo-dir> <session-dir> <branch>
# worktree-path をこの呼び出しだけ上書きして <session-dir>/<repo名> に作る。
# `command wt` で zsh ラッパー（cd 誘導）を迂回し、--no-cd で呼び出し元シェルも動かさない。
# 進捗表示を壊さないよう wt の出力は stderr（= ステップのログ）へ送り、失敗時だけ見せる。
__hr_make_worktree() {
  emulate -L zsh
  local repodir=$1 sdir=$2 branch=$3
  # wt は fetch せず、--base の既定も「ローカルの」デフォルトブランチなので、そのままだと
  # 母体リポジトリを最後に pull した時点から枝が生える。origin を取り込んだうえで
  # base に origin/<default> を明示し、常に最新から切る。
  # （base とブランチ名が異なるので upstream は付かない。これは変更前と同じ挙動。）
  git -C "$repodir" fetch --prune origin >&2 || return 1
  local base
  base=$(__hr_default_branch "$repodir") || {
    print -r -- "デフォルトブランチを特定できません: $repodir" >&2
    return 1
  }
  local -a wtargs
  wtargs=(-C "$repodir" --config-set "worktree-path=\"$sdir/{{ repo }}\"" -y)
  if __hr_branch_exists "$repodir" "$branch"; then
    command wt "${wtargs[@]}" switch --no-cd "$branch" >&2 || return 1
  else
    command wt "${wtargs[@]}" switch --no-cd --create "$branch" --base "origin/$base" >&2 || return 1
  fi
  [[ -d "$sdir/${repodir:t}" ]]
}

# __hr_build_tab <session-dir> <label> <repo...>
# タブを作り「左 main / 右上 <repo1> / 右下 <repo2>」に分割して `tab_id \t main_pane` を出す。
# herdr は名前付きレイアウトを持たず二分木 split だけなので、right → down の 2 手で作る。
__hr_build_tab() {
  emulate -L zsh
  local sdir=$1 label=$2; shift 2
  local created tab_id main_pane prev new_pane direction=right r ws
  ws=$(__hr_workspace_id) || {
    print -r -- "workspace を特定できません（herdr 環境か確認）" >&2
    return 1
  }
  created=$(herdr tab create --workspace "$ws" --label "$label" \
              --cwd "$sdir" --no-focus) || return 1
  tab_id=$(print -r -- "$created" | jq -r '.result.tab.tab_id')
  main_pane=$(print -r -- "$created" | jq -r '.result.root_pane.pane_id')
  [[ -n $tab_id && $tab_id != null && -n $main_pane && $main_pane != null ]] || return 1
  herdr pane rename "$main_pane" main >/dev/null || return 1
  prev=$main_pane
  for r in "$@"; do
    new_pane=$(herdr pane split "$prev" --direction "$direction" --ratio 0.5 \
                 --cwd "$sdir/$r" --no-focus | jq -r '.result.pane.pane_id') || return 1
    [[ -n $new_pane && $new_pane != null ]] || return 1
    herdr pane rename "$new_pane" "$r" >/dev/null
    prev=$new_pane
    direction=down
  done
  print -r -- "$tab_id"$'\t'"$main_pane"
}

# __hr_start_agent <label> <pane> <plan:0|1>
# `agent start` は「入力可能になるまで」待つので、claude が初回の信頼確認ダイアログ
# （新しいディレクトリで出る）で止まると起動済みでも非 0 を返す。その場合は agent 検出で
# 起動成功とみなす。ペインの shell 起動中（agent_pane_busy）は数回リトライ。
# __hr_workspace_id → 今いる workspace の id。特定できなければ 1 を返す。
# herdr はプラグインの pane に HERDR_WORKSPACE_ID を渡さない（代わりに
# HERDR_PLUGIN_CONTEXT_JSON に入れてくる）ので、popup から呼ばれた hello-run が
# 空の id を tab create に渡して workspace_not_found で落ちていた。
__hr_workspace_id() {
  emulate -L zsh
  local ws=${HERDR_WORKSPACE_ID:-}
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

# __hr_find_tab <label> → "<workspace_id><TAB><tab_id>"。無ければ 1 を返す。
# 現在の workspace だけでなく全部を見る。issue のタブは、それを作ったときに居た
# workspace に残るので、別の workspace から hello-run を叩くと現在の workspace には
# 無い。そこで見つけ損なうと、既にあるのに同じラベルのタブをもう 1 つ作ってしまう。
__hr_find_tab() {
  emulate -L zsh
  local label=$1 ws tab
  for ws in ${(f)"$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id // empty')"}; do
    [[ -n $ws ]] || continue
    tab=$(herdr tab list --workspace "$ws" 2>/dev/null \
            | jq -r --arg l "$label" '.result.tabs[]? | select(.label==$l) | .tab_id' | head -1)
    if [[ -n $tab ]]; then
      print -r -- "$ws"$'\t'"$tab"
      return 0
    fi
  done
  return 1
}

__hr_start_agent() {
  emulate -L zsh
  local label=$1 main_pane=$2 plan=$3
  local -a agent_args
  (( plan )) && agent_args=(-- --permission-mode plan)
  integer attempt
  for (( attempt = 0; attempt < 10; attempt++ )); do
    herdr agent start "$label" --kind claude --pane "$main_pane" "${agent_args[@]}" >/dev/null 2>&1 \
      && return 0
    [[ $(herdr agent get "$main_pane" 2>/dev/null | jq -r '.result.agent.agent // empty') == claude ]] \
      && return 0
    sleep 0.5
  done
  return 1
}

# __hr_send_prompt <label> <text>: claude が入力待ち（信頼確認を抜けた状態）になってから送る
__hr_send_prompt() {
  emulate -L zsh
  herdr agent wait "$1" --until idle --timeout "${HELLO_RUN_READY_TIMEOUT:-120000}" >/dev/null 2>&1 \
    || return 1
  herdr agent prompt "$1" "$2" >/dev/null 2>&1
}

# hello-run <issue-url|number> [--prompt|--no-prompt] [--plan] [--no-focus]
hello-run() {
  emulate -L zsh
  setopt local_options no_monitor no_notify
  local issue_arg="" prompt_mode=ask focus=1 plan=0 slug_arg=""
  while (( $# )); do
    case $1 in
      --prompt)    prompt_mode=yes ;;
      --no-prompt) prompt_mode=no ;;
      --plan)      plan=1 ;;
      --no-focus)  focus=0 ;;
      --slug)
        [[ -n ${2:-} ]] || { __hr_err "--slug には値が必要です"; return 2; }
        slug_arg=$2; shift ;;
      --slug=*)    slug_arg=${1#--slug=} ;;
      -h|--help)
        print -r -- "usage: hello-run <issue-url|number> [--slug <slug>] [--prompt|--no-prompt] [--plan] [--no-focus]"
        print -r -- "  --slug  ブランチ名の slug を自分で指定する（省略時は issue タイトルから推定）"
        print -r -- "  --plan  claude を plan モード（--permission-mode plan）で起動する"
        return 0 ;;
      -*) __hr_err "不明な引数: $1"; return 2 ;;
      *)
        [[ -n $issue_arg ]] && { __hr_err "issue は 1 つだけ指定してください"; return 2; }
        issue_arg=$1 ;;
    esac
    shift
  done
  [[ -n $issue_arg ]] || { __hr_err "issue の URL か番号を指定してください"; return 2; }
  if [[ -n $slug_arg ]]; then
    slug_arg=$(__hr_sanitize_slug "$slug_arg") \
      || { __hr_err "--slug に使える文字がありません: 英数字を含めてください"; return 2; }
  fi

  if [[ -z $HELLO_RUN_ROOT ]] || (( ! ${#HELLO_RUN_REPOS} )); then
    __hr_err "HELLO_RUN_ROOT / HELLO_RUN_REPOS が未設定です。~/.pzshrc に設定してください（このファイル冒頭のコメント参照）"
    return 1
  fi

  local -a missing
  local c
  for c in herdr wt gh jq git; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  (( ${#missing} )) && { __hr_err "未インストール: ${missing[*]}"; return 1; }
  [[ -n ${HERDR_ENV:-} ]] || { __hr_err "herdr 環境ではありません（HERDR_ENV が未設定）"; return 1; }

  local parsed repo num
  parsed=$(__hr_parse_issue "$issue_arg") || { __hr_err "issue を解釈できません: $issue_arg"; return 2; }
  repo=${parsed%%$'\t'*}
  num=${parsed##*$'\t'}

  local label="issue-$num" sdir="$HELLO_RUN_ROOT/.sessions/issue-$num"
  local panes="main / ${(j: / :)HELLO_RUN_REPOS}"

  # 既存タブがあれば作り直さず切り替えるだけ（ブランチ名は worktree から読むので haiku 不要）
  local tab_id="" tab_ws="" found cur_ws
  cur_ws=$(__hr_workspace_id) || cur_ws=""
  if found=$(__hr_find_tab "$label"); then
    tab_ws=${found%%$'\t'*}
    tab_id=${found##*$'\t'}
  fi
  if [[ -n $tab_id && -d "$sdir/${HELLO_RUN_REPOS[1]}" ]]; then
    local cur_branch
    cur_branch=$(git -C "$sdir/${HELLO_RUN_REPOS[1]}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    __hr_ui_init "hello-run  ${repo}#${num}  — 既存のタブに切り替え"
    __hr_ui_box "$label" \
      branch  "${cur_branch:-?}" \
      session "${sdir/#$HOME/~}" \
      tab     "$tab_id  ($panes)${${tab_ws:#$cur_ws}:+  @$tab_ws}"
    if (( focus )); then
      # tab focus だけでは別 workspace のタブに移れないので先に workspace を切り替える
      [[ -n $tab_ws && $tab_ws != $cur_ws ]] \
        && herdr workspace focus "$tab_ws" >/dev/null
      herdr tab focus "$tab_id" >/dev/null
    fi
    return 0
  fi

  # ここから先は新規作成。初期プロンプトの確認はこの経路でしか要らないので、
  # 既存タブへの切り替えを済ませた後に訊く。先に訊くと、切り替えるだけの場面でも
  # 入力待ちで止まってしまう。進捗表示を描き始める前であることは変えない
  # （描画中に挟むとカーソル制御が破綻する）。
  if [[ $prompt_mode == ask ]]; then
    if [[ -t 0 ]]; then
      local reply
      read -q "reply?claude に初期プロンプトを送りますか? [y/N] " && prompt_mode=yes || prompt_mode=no
      print
    else
      prompt_mode=no
    fi
  fi

  __hr_ui_init "hello-run  ${repo}#${num}" \
    "issue を取得" "ブランチ名を推定" "worktree を作成" "herdr タブを構成" "claude を起動"

  local tmpd
  tmpd=$(mktemp -d) || return 1

  # 1. issue タイトル（取れなくても致命的ではない）
  local title=""
  __hr_ui_begin 1
  __hr_step "$tmpd/title" __hr_issue_title "$repo" "$num" && title=$(<"$tmpd/title")
  title=${title%%$'\n'*}
  __hr_ui_detail "${title:-（タイトルは取得できず）}"
  __hr_ui_done

  # 2. slug 推定 → ブランチ名（claude が無い / 失敗なら slug 無しにフォールバック）
  local slug=$slug_arg branch="issue-$num"
  __hr_ui_begin 2
  if [[ -n $slug ]]; then
    __hr_ui_detail "指定された slug を使用"
  elif [[ -n $title ]]; then
    __hr_step "$tmpd/slug" __hr_slugify "$title" && slug=$(<"$tmpd/slug")
    slug=${slug%%$'\n'*}
  fi
  [[ -n $slug ]] && branch="issue-$num/$slug"
  __hr_ui_detail "$branch"
  __hr_ui_done

  # 3. worktree
  mkdir -p "$sdir" || return 1
  local r rdir
  __hr_ui_begin 3
  for r in "${HELLO_RUN_REPOS[@]}"; do
    rdir="$HELLO_RUN_ROOT/$r"
    if [[ ! -d "$rdir/.git" ]]; then
      __hr_ui_detail "$r"
      __hr_ui_fail
      __hr_err "リポジトリが見つかりません: $rdir"
      return 1
    fi
    if [[ -d "$sdir/$r" ]]; then
      __hr_ui_detail "$r (既存)"
      continue
    fi
    __hr_ui_detail "$r"
    if ! __hr_step "$tmpd/wt" __hr_make_worktree "$rdir" "$sdir" "$branch"; then
      __hr_ui_fail "$__HR_STEP_LOG"
      __hr_err "worktree の作成に失敗しました: $r"
      return 1
    fi
  done
  __hr_ui_detail "${(j:, :)HELLO_RUN_REPOS}"
  __hr_ui_done

  # 4. herdr タブ + ペイン
  local main_pane
  __hr_ui_begin 4
  __hr_ui_detail "$panes"
  if ! __hr_step "$tmpd/tab" __hr_build_tab "$sdir" "$label" "${HELLO_RUN_REPOS[@]}"; then
    __hr_ui_fail "$__HR_STEP_LOG"
    __hr_err "タブの作成に失敗しました"
    return 1
  fi
  parsed=$(<"$tmpd/tab")
  tab_id=${parsed%%$'\t'*}
  main_pane=${${parsed##*$'\t'}%%$'\n'*}
  __hr_ui_detail "$tab_id  ($panes)"
  __hr_ui_done

  # 5. claude 起動（＋任意の初期プロンプト）
  __hr_ui_begin 5
  __hr_ui_detail "起動を待っています"
  if __hr_step "$tmpd/agent" __hr_start_agent "$label" "$main_pane" "$plan"; then
    __hr_ui_detail "${main_pane}$( (( plan )) && print -n '  plan モード')"
    __hr_ui_done
  else
    __hr_ui_fail "$__HR_STEP_LOG"
    __hr_err "claude の起動に失敗しました（ペインは作成済み: $main_pane）"
  fi

  # 信頼確認ダイアログを操作できるよう、プロンプト送信より先にタブへ移る
  (( focus )) && herdr tab focus "$tab_id" >/dev/null

  if [[ ${__HR_UI_STATES[5]} == done && $prompt_mode == yes ]]; then
    local text="https://github.com/$repo/issues/$num に取り組みます。カレントディレクトリ直下に ${HELLO_RUN_REPOS[*]} の worktree（ブランチ $branch）があります。まず issue の内容を確認してください。"
    __hr_ui_begin 5
    __hr_ui_detail "入力待ちになるまで待っています"
    if __hr_step "$tmpd/prompt" __hr_send_prompt "$label" "$text"; then
      __hr_ui_detail "${main_pane}  プロンプト送信済み"
      __hr_ui_done
    else
      __hr_ui_detail "${main_pane}  プロンプトは未送信"
      __hr_ui_done
      __hr_err "初期プロンプトを送れませんでした。claude が入力待ちになったら以下を貼ってください:"
      print -r -- "$text"
    fi
  fi

  rm -rf "$tmpd"
  __hr_ui_box "$label" \
    branch  "$branch" \
    session "${sdir/#$HOME/~}" \
    tab     "$tab_id  ($panes)"
}
