# エイリアス定義。dot_zshrc から source。

alias sudo='sudo '
alias vi='vim'
alias ll='ls -l'
alias msql='mysql -u root -p'
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'
alias mkdir='mkdir -p'
alias gl='git log --oneline --graph --decorate --color=always | less -R'
alias gg='cd $(ghq root)/$(ghq list | peco)'
alias g='git'
alias get='ghq get'
alias npm-list='npm list --depth=0'
alias psql-run='postgres -D /usr/local/var/postgres'
alias sed='gsed'
alias branch-all-delete="git branch --merged|egrep -v '\*|develop|master'|xargs git branch -d"
alias debug-chrome="/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=54888 --no-first-run --no-default-browser-check --user-data-dir=$(mktemp -d -t 'chrome-remote_data_dir')"
alias ibrew='arch -x86_64 /usr/local/bin/brew'
alias dc='docker-compose'

############
# Claude
############
alias claudecode="AWS_PROFILE=claude claude"
alias cw='~/git_clone/github.com/progrit/work-log/scripts/claudework.sh'
