#!/usr/bin/env zsh
# 1 ファイル分の diff を delta の side-by-side で描く。fzf の preview と、
# enter で開く全画面表示の両方がこれを呼ぶ（--pager 付きが全画面）。
#
# 使い方: show.zsh <path> [<old-path>] [--pager]
# rename のときに旧パスも要るのは、git に両方渡さないと rename として検出されず、
# 中身が変わっていないファイルが「全行追加」に見えてしまうため。
emulate -L zsh

source "${0:A:h}/lib.zsh"

typeset file=$1 old= paging=never
shift 2>/dev/null
typeset a
for a in "$@"; do
  case $a in
    --pager) paging=always ;;
    '') ;;
    *) old=$a ;;
  esac
done
[[ -n $file ]] || exit 0

typeset repo
repo=$(gd_repo_dir) || { print -ru2 -- "git リポジトリではありません"; exit 1 }
gd_resolve_base "$repo"

# preview のときは fzf が幅を教えてくれる。全画面のときは端末幅。
# 非対話で呼ばれると zsh の $COLUMNS が 0 になり、side-by-side の桁が潰れて
# 本文が 1 行も出なくなるので、狭すぎる値は端末幅 → 120 に落とす。
typeset -i width=${FZF_PREVIEW_COLUMNS:-$COLUMNS}
(( width < 40 )) && width=$(tput cols 2>/dev/null || print 120)
(( width < 40 )) && width=120

typeset -a delta_opts
# side-by-side は行番号も出す。ファイル名のヘッダは残す（rename や削除がそこに出る）。
delta_opts=(
  --side-by-side --width=$width --paging=$paging
  --hunk-header-style='line-number syntax'
  --hunk-header-decoration-style='#555555 ul'
)

typeset -a paths
paths=("$file")
[[ -n $old ]] && paths=("$old" "$file")

# 未追跡ファイルは diff に出ないので、空ファイルとの差分として見せる。
# 判定を「追跡されているか」ではなく「未追跡か」にするのは、base で消したファイルが
# どちらにも居ないため（--error-unmatch で見ると未追跡扱いになり、存在しないパスを掴む）。
if [[ -n $(git -C "$repo" ls-files --others --exclude-standard -- "$file" 2>/dev/null) ]]; then
  git -C "$repo" diff --no-index -- /dev/null "$file" 2>/dev/null
else
  git -C "$repo" diff "$GD_BASE" -- $paths
fi | delta $delta_opts
