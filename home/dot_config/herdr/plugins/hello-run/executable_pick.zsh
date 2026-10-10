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

# 検索は org 全体。org 名そのものは持たず、既定では ~/.pzshrc の
# HELLO_RUN_ISSUE_REPO（<org>/<repo>）の所有者部分から取る。
HELLO_RUN_ISSUE_ORG="${HELLO_RUN_ISSUE_ORG:-${HELLO_RUN_ISSUE_REPO%%/*}}"
[[ -n $HELLO_RUN_ISSUE_ORG ]] \
  || die "HELLO_RUN_ISSUE_ORG か HELLO_RUN_ISSUE_REPO を $HELLO_RUN_PRIVATE_RC に書いてください"

# issue 一覧は issues.zsh が吐く。fzf の reload バインドからも同じものを呼ぶ
# （--bind はコンマでバインドを区切るので、jq を直接埋めると壊れる。issues.zsh 冒頭参照）。
typeset -r issues=${0:A:h}/issues.zsh
[[ -x $issues ]] || die "issues.zsh が見つかりません: $issues"
# issues.zsh は印を付けるのに HELLO_RUN_ROOT（セッションの置き場）も見る
export HELLO_RUN_ISSUE_ORG HELLO_RUN_LIMIT HELLO_RUN_ROOT

# 一覧は自分にアサインされた open issue だけ。0 件なら作る対象が無いので終わる。
typeset initial
initial=$("$issues") || die "gh search issues に失敗しました"
[[ -n $initial ]] \
  || die "自分にアサインされた open issue がありません: $HELLO_RUN_ISSUE_ORG"

# 1 列目の URL は hello-run に渡すためのもので、画面には出さない（--with-nth=2）。
#
# --disabled で絞り込みを切ってある。候補は自分の issue だけで十数件なので検索が要らず、
# 切ると ctrl 無しの素のキー（r）をバインドできる。ctrl-r は端末側の履歴検索と当たる。
# 絞り込みが無いと打った文字が入力欄に残るだけで紛らわしいので、change で消している。
typeset selected
selected=$(
  print -r -- "$initial" | fzf \
    --delimiter=$'\t' --with-nth=2 \
    --prompt='issue> ' \
    --header=$"${HELLO_RUN_ISSUE_ORG}  —  自分の issue   ● タブあり  ○ worktree のみ  ・なし\nenter: 開く / r: 取り直す（キャッシュ無視） / esc: 閉じる" \
    --disabled \
    --bind="r:reload(${(q)issues} --refresh)" \
    --bind='change:clear-query' \
    --preview='gh issue view {1}' \
    --preview-window='right,55%,wrap'
)
# fzf を Esc で抜けた / 候補が無い。黙って popup を閉じる。
[[ -n $selected ]] || exit 0

# issue 番号はリポジトリ間で一意でないので、番号ではなく URL を渡す。
typeset url=${selected%%$'\t'*}
[[ $url == https://github.com/*/issues/<->  ]] \
  || die "issue の URL を取り出せませんでした: $selected"

# 成功時はそのまま popup を閉じる。hello-run が最後に新しいタブへ focus するので、
# ここで待つとユーザーは popup 越しにそのタブを見ることになる。
hello-run "$url" || die "hello-run が失敗しました（終了コード $?）"
