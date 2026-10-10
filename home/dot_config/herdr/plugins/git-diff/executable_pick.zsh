#!/usr/bin/env zsh
# kokikono.git-diff の中身。PR を作る直前に差分を GitHub の Files changed のように見る。
# 左に変更ファイル一覧（files.zsh）、右に delta の side-by-side（show.zsh）。
# herdr から popup として起動される（argv は herdr-plugin.toml を参照）。
emulate -L zsh
setopt pipe_fail

source "${0:A:h}/lib.zsh"

typeset -a missing
for c in git fzf delta; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
(( ${#missing} )) && gd_die "未インストール: ${missing[*]}"

typeset repo
repo=$(gd_repo_dir) \
  || gd_die "git リポジトリの中ではありません（フォーカス中のペインの cwd を見ています）"
gd_resolve_base "$repo"

# 一覧も preview も同じリポジトリを見るよう、解決済みのものを子プロセスへ渡す。
# フォーカスは popup を開いた時点のものなので、ここで固定しないと preview が別の
# リポジトリを見にいきうる。
export GIT_DIFF_REPO="$repo"

typeset -r files=${0:A:h}/files.zsh
typeset -r show=${0:A:h}/show.zsh
[[ -x $files && -x $show ]] || gd_die "files.zsh / show.zsh が見つかりません: ${0:A:h}"

typeset initial
initial=$("$files") || gd_die "差分の取得に失敗しました"
[[ -n $initial ]] || gd_die "$GD_BASE_LABEL との差分はありません"

typeset branch
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)

# 画面に出すのは 2 列目だけ（--with-nth=2）。1 列目のパスと 3 列目の rename 旧パスは
# show.zsh に渡すためのもので、見せない。
# ファイル数は十数〜数十件になるので、hello-run と違って絞り込みは生かしてある。
print -r -- "$initial" | fzf \
  --ansi \
  --delimiter=$'\t' --with-nth=2 \
  --prompt='file> ' \
  --header=$"${repo:t}  ${branch}  ←  ${GD_BASE_LABEL}\nenter: 全画面で見る / ctrl-r: 取り直す / esc: 閉じる   ● 未コミットを含む  ○ コミット済みのみ" \
  --preview="${(q)show} {1} {3}" \
  --preview-window='right,72%,nowrap,border-left' \
  --bind="ctrl-r:reload(${(q)files})" \
  --bind="enter:execute(${(q)show} {1} {3} --pager)" \
  >/dev/null

# enter でも fzf を閉じないので、抜けたら popup を閉じるだけ。
exit 0
