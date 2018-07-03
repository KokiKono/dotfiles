# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH=/Users/kokikono/.oh-my-zsh

# Set name of the theme to load. Optionally, if you set this to "random"
# it'll load a random theme each time that oh-my-zsh is loaded.
# See https://github.com/robbyrussell/oh-my-zsh/wiki/Themes
ZSH_THEME="robbyrussell"

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion. Case
# sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment the following line to disable bi-weekly auto-update checks.
# DISABLE_AUTO_UPDATE="true"

# Uncomment the following line to change how often to auto-update (in days).
# export UPDATE_ZSH_DAYS=13

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# The optional three formats: "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Custom plugins may be added to ~/.oh-my-zsh/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(git)

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# ssh
# export SSH_KEY_PATH="~/.ssh/rsa_id"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

export LANG=ja_JP.UTF-8
export LESSCHARSET=utf-8
export EDITOR=vim
export CLICOLOR=true

SUSHI=$'\U1F363 ' # 寿司
UNKO=$'\U1F4A9 ' # うんこ
BIKE=$'🏍'
PAT=$'🚔'
# 色を使用出来るようにする
autoload -Uz colors

# 🚔ロンプト
# 1行表示
# PROMPT="%~ %# "
# 2行表示
#PROMPT="%{${fg[green]}%}[%n@%m]%{${reset_color}%} %~ %(?.${SUSHI}.${UNKO}) "
#PROMPT="%{${fg[green]}%}[%n@%m]%{${reset_color}%} %~ %(?.${BIKE}.${PAT}) "
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

# 補完後、メニュー選択モードになり左右キーで移動が出来る
#zstyle ':completion:*:default' menu select=2

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


#ls色付け
if [ "$(uname)" = 'Darwin' ]; then
   # export LSCOLORS=xbfxcxdxbxegedabagacad
    alias ls='ls -aFG'
else
    eval `dircolors ~/.colorrc`
    alias ls='ls --color=auto -aF'
fi


# プロキシサーバ: proxy.xxx.yyy.zzz.jp:80
# ネットワーク設定名: プロキシ設定
proxy_name=http://ohs40313:B61747641@proxy03.osaka.hal.ac.jp:8080
#switch_trigger=school
if [ "`networksetup -getcurrentlocation`" = "$switch_trigger" ]; then
   export http_proxy=$proxy_name
   export https_proxy=$proxy_name
   export ftp_proxy=$proxy_name
   export all_proxy=$proxy_name
   git config --global http.proxy $proxy_name
   git config --global https.proxy $proxy_name
   git config --global url."https://".insteadOf git://
else
   unset http_proxy
   unset https_proxy
   unset ftp_proxy
   unset all_proxy
   git config --global --unset http.proxy
   git config --global --unset https.proxy
   git config --global --unset url."https://".insteadOf
fi


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
alias g='cd $(ghq root)/$(ghq list | peco)'
alias get='ghq get'
alias gh='hub browse $(ghq list | peco | cut -d “/” -f 2,3)'
alias npm-list='npm list --depth=0'
alias react-native-git-upgrade='.npm-global/bin/react-native-git-upgrade'
alias react-native-app='cd ~/MyApplication/react-native'
alias npm-react-navigation='npm install --save react-navigation'
alias npm-native-base='npm install native-base --save'
alias npm-flux='npm install flux --save'
alias npm-events='npm install events --save'
alias npm-easy-grid='npm install react-native-easy-grid --save'
alias npm-vector-icons='npm install react-native-vector-icons --save'
alias npm-react-native-maps='npm install react-native-maps --save'
alias psql-run='postgres -D /usr/local/var/postgres'

#nodebrew　パス
export PATH=$HOME/.nodebrew/current/bin:$PATH
#create-react-app パス
export PATH=$HOME/.node_modules_global/bin:$PATH
#brew パス
export PATH=/usr/local/bin:$PATH
#react-native パス
export PATH=/usr/local/lib/node_modules/react-native-cli/node_modules/.bin:$PATH
#android パス
export ANDROID_HOME=${HOME}/Library/Android/sdk
export PATH=${PATH}:${ANDROID_HOME}/tools
export PATH=${PATH}:${ANDROID_HOME}/platform-tools
export PATH=$PATH:$GOPATH/bin
export PATH=/Users/kokikono/.npm-global/bin:$PATH
if [ -x "`which go`" ]; then

    export GOPATH=$HOME/go

    export PATH=$PATH::$GOPATH/bin

fi
export PATH=$HOME/.npm-global/lib:$PATH
export PATH=$HOME/.nodebrew/current/bin:$PATH
export PATH=$HOME/.npm-global/lib/node_modules/n/bin:$PATH
export PATH=$HOME/.npm-global/lib/node_modules/react-native-git-upgrade:$PATH
export PATH="$(brew --prefix homebrew/php/php70)/bin:$PATH"
# The next line updates PATH for the Google Cloud SDK.
if [ -f /Users/kokikono/google-cloud-sdk/path.zsh.inc ]; then
  source '/Users/kokikono/google-cloud-sdk/path.zsh.inc'
fi
 
 # The next line enables shell command completion for gcloud.
 if [ -f /Users/kokikono/google-cloud-sdk/completion.zsh.inc ]; then
    source '/Users/kokikono/google-cloud-sdk/completion.zsh.inc'
 fi
export PATH=~/go_appengine/:$PATH


[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
export PATH="$PYENV_ROOT/versions/anaconda3-5.0.0/bin/:$PATH"
#export PYTHONPATH=/Users/kokikono/.pyenv/shims/python3
