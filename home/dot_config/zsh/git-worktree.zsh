# git worktree / branch のクリーンアップ関数（fzf + gh）。
# 参考: https://www.playpark.co.jp/blog/git-worktree-fzf-branch-cleanup
# 依存: git, fzf, gh(wrm のみ)。worktree の作成/移動は既存 wtp を使う。

# リポジトリのデフォルトブランチ推定（origin/HEAD → main/master）
__gwt_main_branch() {
  local ref
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  [[ -n "$ref" ]] && { echo "${ref#origin/}"; return; }
  local b; for b in main master; do
    git show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }
  done
  echo main
}

# wrm: PR が MERGED（または PR 無し）の worktree を一括削除
wrm() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo"; return 1; }
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh 未認証のため中止（OPEN な PR の誤削除防止）。'gh auth login' を。" >&2; return 1
  fi
  git worktree prune
  local current main_wt line path branch state; local -a candidates
  current=$(git rev-parse --show-toplevel 2>/dev/null)
  main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *)   branch="${line#branch refs/heads/}"
        if [[ "$path" != "$current" && "$path" != "$main_wt" ]]; then
          state=$(gh pr view "$branch" --json state -q .state 2>/dev/null)
          [[ "$state" == "MERGED" || -z "$state" ]] && \
            candidates+=("$path"$'\t'"$branch"$'\t'"${state:-NO-PR}")
        fi ;;
      "") path=""; branch="" ;;
    esac
  done < <(git worktree list --porcelain)
  (( ${#candidates[@]} == 0 )) && { echo "削除対象の worktree はありません。"; return 0; }
  echo "以下の worktree を削除します (path / branch / state):"
  printf '  %s\n' "${candidates[@]}"
  echo -n "続行しますか？ [y/N] "; local ans; read -r ans
  [[ "$ans" == [yY] ]] || { echo "中止。"; return 1; }
  local c; for c in "${candidates[@]}"; do
    path="${c%%$'\t'*}"; branch="${${c#*$'\t'}%%$'\t'*}"
    git worktree remove "$path" && echo "Removed: $branch ($path)"
  done
}

# brm: マージ済み / リモート削除済み(gone) のローカルブランチを掃除
brm() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo"; return 1; }
  git fetch --prune >/dev/null 2>&1
  local main current base; main=$(__gwt_main_branch)
  current=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
  if git show-ref --verify --quiet "refs/remotes/origin/$main"; then base="origin/$main"; else base="$main"; fi
  local -a merged gone candidates
  merged=("${(@f)$(git branch --merged "$base" --format='%(refname:short)')}")
  gone=("${(@f)$(git branch --format='%(refname:short) %(upstream:track)' | awk '$2=="[gone]"{print $1}')}")
  local b; for b in "${merged[@]}" "${gone[@]}"; do
    [[ -z "$b" || "$b" == "$main" || "$b" == "$current" ]] && continue
    (( ${candidates[(Ie)$b]} )) || candidates+=("$b")
  done
  (( ${#candidates[@]} == 0 )) && { echo "掃除対象のブランチはありません。"; return 0; }
  echo "以下のローカルブランチを削除します (merged→$base / gone):"
  printf '  %s\n' "${candidates[@]}"
  echo -n "続行しますか？ [y/N] "; local ans; read -r ans
  [[ "$ans" == [yY] ]] || { echo "中止。"; return 1; }
  for b in "${candidates[@]}"; do git branch -D "$b"; done
}

# bd: fzf で選んでローカルブランチ削除（保護ブランチ除外・worktree使用中除外）
bd() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo"; return 1; }
  local main protected branches selected b ans; main=$(__gwt_main_branch)
  protected='^(main|master|dev|develop|staging|production)$'
  branches=$(git for-each-ref --format='%(refname:short)%09%(worktreepath)' refs/heads \
    | awk -F'\t' '$2==""{print $1}' | grep -vE "$protected")
  [[ -z "$branches" ]] && { echo "削除可能なブランチがありません。"; return 0; }
  selected=$(echo "$branches" | __GWT_MAIN="$main" fzf --multi --ansi --preview-window=right:60% \
    --preview 'if git merge-base --is-ancestor {} "$__GWT_MAIN" 2>/dev/null; then
                 echo "[MERGED] $__GWT_MAIN にマージ済み"; else echo "[UNMERGED] 未マージコミットあり"; fi
               echo; git log --oneline -20 --color=always {}')
  [[ -z "$selected" ]] && return 0
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    if git merge-base --is-ancestor "$b" "$main" 2>/dev/null; then
      git branch -d "$b"
    else
      echo -n "'$b' は未マージです。強制削除しますか？ [y/N] "; read -r ans
      [[ "$ans" == [yY] ]] && git branch -D "$b" || echo "skip: $b"
    fi
  done <<< "$selected"
}
