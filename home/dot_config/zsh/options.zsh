# zsh の挙動設定（locale / setopt / 履歴 / 補完 / キーバインド）。dot_zshrc から source。

export LANG=ja_JP.UTF-8
export LESSCHARSET=utf-8
export EDITOR=vim
export CLICOLOR=true

# 他のターミナルとヒストリーを共有
setopt share_history
# ヒストリーに重複を表示しない
setopt histignorealldups
# コマンドミスを修正
setopt correct
# ディレクトリ名で移動
setopt auto_cd
# push自動
setopt auto_pushd
# deleteキーを使えるように
bindkey "^[[3~" delete-char

# 自動補完を有効にする
# コマンドの引数やパス名を途中まで入力して <Tab> を押すといい感じに補完してくれる
# 例： `cd path/to/<Tab>`, `ls -<Tab>`
autoload -U compinit; compinit

# 補完で大文字にもマッチ
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# 履歴ファイルの保存先
export HISTFILE=${HOME}/.zsh_history
# メモリに保存される履歴の件数
export HISTSIZE=1000
# 履歴ファイルに保存される履歴の件数
export SAVEHIST=100000
# 開始と終了を記録
setopt EXTENDED_HISTORY

set -o vi
