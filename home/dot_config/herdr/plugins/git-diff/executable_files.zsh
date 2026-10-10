#!/usr/bin/env zsh
# 変更ファイルの一覧を TSV で吐く。1 列目が機械が使うパス、2 列目が fzf に見せる 1 列、
# 3 列目は rename の旧パス（無ければ空）。桁揃えは fzf がやってくれないのでここで
# 組み立てる（pick.zsh は --with-nth=2 で見せ、{1} と {3} を show.zsh に渡す）。
#
# 一覧は merge-base からワーキングツリーまでの差分（= PR に載る差分 + 未コミット）に
# 未追跡ファイルを足したもの。未コミットを含むものには ● を付けて区別する。
emulate -L zsh
setopt pipe_fail

source "${0:A:h}/lib.zsh"

typeset repo
repo=$(gd_repo_dir) || gd_die "git リポジトリの中ではありません"
gd_resolve_base "$repo"

# git には -z で吐かせ、tr で行に均してから awk に渡す。macOS の awk は RS="\0" を
# 扱えず最初のレコードしか読まないので、NUL のまま awk に食わせてはいけない。
#
# --numstat の rename は「add del（空）」「旧」「新」の 3 レコードに割れるので、
# そこだけ状態を持って 1 行に畳む。
typeset -a rows
rows=(${(f)"$(
  git -C "$repo" diff --numstat -z "$GD_BASE" -- 2>/dev/null | tr '\0' '\n' | awk '
    BEGIN { OFS = "\t" }
    {
      if (pending == 1) { old = $0; pending = 2; next }
      if (pending == 2) { print add, del, $0, old; pending = 0; next }
      if ($0 == "") next
      n = split($0, f, "\t")
      add = f[1]; del = f[2]
      if (n < 3 || f[3] == "") { pending = 1; next }
      print add, del, f[3], ""
    }'
)"})

# ステータス文字（A/M/D/R…）。rename / copy はレコードが 3 つになる。
typeset -A status_of
typeset st file add del old label row mark counts n
while IFS=$'\t' read -r st file; do
  [[ -n $file ]] && status_of[$file]=$st
done < <(
  git -C "$repo" diff --name-status -z "$GD_BASE" -- 2>/dev/null | tr '\0' '\n' | awk '
    {
      if ($0 == "") next
      if (need == 0) {
        st = substr($0, 1, 1)
        need = (st == "R" || st == "C") ? 2 : 1
        cnt = 0
        next
      }
      cnt++
      if (need == 2 && cnt == 1) next          # rename の旧パスは捨てる
      print st "\t" $0
      need = 0
    }'
)

# 未コミット（staged / unstaged）と未追跡。印の材料。
typeset -A dirty
while IFS= read -r file; do
  [[ -n $file ]] && dirty[$file]=1
done < <(git -C "$repo" diff --name-only -z HEAD -- 2>/dev/null | tr '\0' '\n')

typeset -a untracked
untracked=(${(f)"$(git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null | tr '\0' '\n')"})
for file in $untracked; do
  [[ -n $file ]] || continue
  dirty[$file]=1
  # 未追跡は diff に出ないので、全行追加として自分で足す
  n=$(wc -l <"$repo/$file" 2>/dev/null | tr -d ' ')
  rows+=("${n:-0}"$'\t'"0"$'\t'"$file"$'\t')
  status_of[$file]=A
done

(( ${#rows} )) || exit 0

# 桁揃えのためにパス列の最大長を取る（長すぎるものに引きずられないよう上限を置く）
typeset -i width=0 cap=${GIT_DIFF_PATH_WIDTH:-64} i=0
typeset -a labels
for row in $rows; do
  IFS=$'\t' read -r add del file old <<<"$row"
  [[ -n $file ]] || continue
  label=$file
  [[ -n $old ]] && label="$old → $file"
  labels+=("$label")
  (( ${#label} > width )) && width=${#label}
done
(( width > cap )) && width=cap

typeset -A color
color=(A $'\e[32m' M $'\e[33m' D $'\e[31m' R $'\e[34m' C $'\e[34m' T $'\e[35m')
typeset reset=$'\e[0m' green=$'\e[32m' red=$'\e[31m' dim=$'\e[2m'

for row in $rows; do
  IFS=$'\t' read -r add del file old <<<"$row"
  [[ -n $file ]] || continue
  (( i++ ))
  st=${status_of[$file]:-M}
  mark=○
  [[ -n ${dirty[$file]:-} ]] && mark=●
  if [[ $add == - || $del == - ]]; then
    counts="${dim}binary${reset}"
  else
    counts="${green}+${add}${reset} ${red}-${del}${reset}"
  fi
  printf '%s\t%s%s%s %s %-*s %s\t%s\n' \
    "$file" "${color[$st]:-}" "$st" "$reset" "$mark" "$width" "${labels[$i]}" "$counts" "$old"
done
