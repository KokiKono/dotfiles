#!/usr/bin/env zsh
# kokikono.hello-run プラグインの中身。issue を fzf で選んで hello-run に渡す。
# herdr から popup として起動される（argv は herdr-plugin.toml を参照）。
#
# hello-run は ~/.config/zsh/hello-run.zsh の zsh 関数で、対象 org / リポジトリは
# ~/.pzshrc（chezmoi 管理外）にある。対話シェルではない ここでは .zshrc が読まれないので、
# その 2 つを自分で source する。
emulate -L zsh
setopt pipe_fail

HELLO_RUN_PRIVATE_RC="${HELLO_RUN_PRIVATE_RC:-$HOME/.pzshrc}"
HELLO_RUN_SOURCE="${HELLO_RUN_SOURCE:-$HOME/.config/zsh/hello-run.zsh}"
HELLO_RUN_LIMIT="${HELLO_RUN_LIMIT:-100}"

# popup はコマンドが終了した瞬間に閉じる。異常終了の理由を読む時間が無くなるので、
# 失敗時だけキー入力を待ってから閉じる。
die() {
  print -ru2 -- "hello-run: $*"
  if [[ -t 0 ]]; then
    print -rn -- $'\n  何かキーを押すと閉じます '
    read -k 1
  fi
  exit 1
}

[[ -r $HELLO_RUN_SOURCE ]] || die "hello-run が見つかりません: $HELLO_RUN_SOURCE（chezmoi apply 済みか確認）"
[[ -r $HELLO_RUN_PRIVATE_RC ]] && source "$HELLO_RUN_PRIVATE_RC"
source "$HELLO_RUN_SOURCE"

typeset -a missing
for c in gh fzf jq wt git herdr; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
(( ${#missing} )) && die "未インストール: ${missing[*]}"

[[ -n ${HELLO_RUN_ISSUE_REPO:-} ]] \
  || die "HELLO_RUN_ISSUE_REPO が未設定です。$HELLO_RUN_PRIVATE_RC に書いてください"

# issue 一覧は issues.zsh が吐く。fzf の reload バインドからも同じものを呼ぶ
# （--bind はコンマでバインドを区切るので、jq を直接埋めると壊れる。issues.zsh 冒頭参照）。
typeset -r issues=${0:A:h}/issues.zsh
[[ -x $issues ]] || die "issues.zsh が見つかりません: $issues"
export HELLO_RUN_ISSUE_REPO HELLO_RUN_LIMIT

# 自分の issue を先に見せる。0 件なら黙って全 open issue に切り替える
# （空の fzf を出して ctrl-a を押させるより親切）。
typeset initial scope
initial=$("$issues" mine) || die "gh issue list に失敗しました"
if [[ -n $initial ]]; then
  scope="自分の issue"
else
  initial=$("$issues" all) || die "gh issue list に失敗しました"
  scope="全 issue（自分にアサインされた open issue は無し）"
fi
[[ -n $initial ]] || die "open な issue がありません: $HELLO_RUN_ISSUE_REPO"

typeset selected
selected=$(
  print -r -- "$initial" | fzf \
    --delimiter=$'\t' --with-nth=1,2,3 \
    --prompt='issue> ' \
    --header=$"${HELLO_RUN_ISSUE_REPO}  —  ${scope}  |  enter: 作業環境を作る / ctrl-a: 全 issue / ctrl-o: 自分の issue" \
    --bind="ctrl-a:reload(${(q)issues} all)" \
    --bind="ctrl-o:reload(${(q)issues} mine)" \
    --preview="gh issue view {1} --repo ${(q)HELLO_RUN_ISSUE_REPO}" \
    --preview-window='right,55%,wrap'
)
# fzf を Esc で抜けた / 候補が無い。黙って popup を閉じる。
[[ -n $selected ]] || exit 0

typeset num=${selected%%$'\t'*}
[[ $num == <-> ]] || die "issue 番号を取り出せませんでした: $selected"

# 成功時はそのまま popup を閉じる。hello-run が最後に新しいタブへ focus するので、
# ここで待つとユーザーは popup 越しにそのタブを見ることになる。
hello-run "$num" || die "hello-run が失敗しました（終了コード $?）"
