# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH=~/.oh-my-zsh

# Set name of the theme to load. Optionally, if you set this to "random"
# it'll load a random theme each time that oh-my-zsh is loaded.
# See https://github.com/robbyrussell/oh-my-zsh/wiki/Themes
ZSH_THEME="robbyrussell"

plugins=(git)

source $ZSH/oh-my-zsh.sh

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

#エイリアス
alias sudo='sudo '
alias vi='vim'
alias ll='ls -l'
alias msql='mysql -u root -p'
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -p'
alias gl='git log --oneline --graph --decorate'
alias gg='cd $(ghq root)/$(ghq list | peco)'
alias g='git'
alias get='ghq get'
alias npm-list='npm list --depth=0'
alias psql-run='postgres -D /usr/local/var/postgres'
alias sed='gsed'
alias branch-all-delete="git branch --merged|egrep -v '\*|develop|master'|xargs git branch -d"
alias debug-chrome="/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=54888 --no-first-run --no-default-browser-check --user-data-dir=$(mktemp -d -t 'chrome-remote_data_dir')"

eval "$(nodenv init -)"
alias nodenv-fetch='(cd ~/.nodenv/plugins/node-build; git pull)'
export PATH="/usr/local/opt/mysql-client/bin:$PATH"
export GREN_GITHUB_TOKEN=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
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"
export PATH="/usr/local/opt/openjdk/bin:$PATH"
export CPPFLAGS="-I/usr/local/opt/openjdk/include"
export AWS_PROFILE=grit

# Added by serverless binary installer
export PATH="$HOME/.serverless/bin:$PATH"
export GPG_TTY=$(tty)

set -o vi
# goenv 設定
export GOENV_ROOT="$HOME/.goenv"
export PATH="$GOENV_ROOT/bin:$PATH"
eval "$(goenv init -)"
export PATH="$GOROOT/bin:$PATH"
export PATH="$PATH:$GOPATH/bin"

# Python
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"

export PATH="$HOME/.anyenv/bin:$PATH"
eval "$(anyenv init -)"
export PATH="/usr/local/opt/openjdk/bin:$PATH"

### MANAGED BY RANCHER DESKTOP START (DO NOT EDIT)
export PATH="~/.rd/bin:$PATH"
### MANAGED BY RANCHER DESKTOP END (DO NOT EDIT)
eval "$(nodenv init -)"
