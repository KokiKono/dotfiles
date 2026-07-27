# git worktree / branch のクリーンアップ関数（fzf + gh）。
# 参考: https://www.playpark.co.jp/blog/git-worktree-fzf-branch-cleanup
# 依存: git, fzf, gh(wrm/wgs)。worktree の作成/移動は既存 wtp を使う。
# wgs = 複数リポジトリ横断で wrm 条件の worktree を検索（read-only）。

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
#   -f, --force : 確認プロンプトを省略し、git worktree remove も --force で実行
#                 （変更/未追跡ファイルを含む worktree も削除）
wrm() {
  local force=0 arg
  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=1 ;;
      -h|--help)  echo "usage: wrm [-f|--force]"; return 0 ;;
      *) echo "wrm: 不明な引数: $arg" >&2; return 2 ;;
    esac
  done
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo"; return 1; }
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh 未認証のため中止（OPEN な PR の誤削除防止）。'gh auth login' を。" >&2; return 1
  fi
  git worktree prune
  # NOTE: zsh では `path` は $PATH に連動する特殊配列。local 変数名に使うと関数内で
  # PATH が空になり git/awk が command not found になるため、必ず別名（wtpath）を使う。
  local current main_wt line wtpath branch state; local -a candidates
  current=$(git rev-parse --show-toplevel 2>/dev/null)
  main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wtpath="${line#worktree }" ;;
      branch\ *)   branch="${line#branch refs/heads/}"
        if [[ "$wtpath" != "$current" && "$wtpath" != "$main_wt" ]]; then
          state=$(gh pr view "$branch" --json state -q .state 2>/dev/null)
          [[ "$state" == "MERGED" || -z "$state" ]] && \
            candidates+=("$wtpath"$'\t'"$branch"$'\t'"${state:-NO-PR}")
        fi ;;
      "") wtpath=""; branch="" ;;
    esac
  done < <(git worktree list --porcelain)
  (( ${#candidates[@]} == 0 )) && { echo "削除対象の worktree はありません。"; return 0; }
  echo "以下の worktree を削除します (path / branch / state):"
  printf '  %s\n' "${candidates[@]}"
  if (( force )); then
    echo "--force: 確認を省略して削除します。"
  else
    echo -n "続行しますか？ [y/N] "; local ans; read -r ans
    [[ "$ans" == [yY] ]] || { echo "中止。"; return 1; }
  fi
  local c; local -a rm_opts; (( force )) && rm_opts=(--force)
  for c in "${candidates[@]}"; do
    wtpath="${c%%$'\t'*}"; branch="${${c#*$'\t'}%%$'\t'*}"
    git worktree remove "${rm_opts[@]}" "$wtpath" && echo "Removed: $branch ($wtpath)"
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

# __wgs_scan_repo: 1 リポジトリを走査し、wrm 条件（PR MERGED / PR 無し）の worktree を
# `state \t repo \t branch \t path` で stdout に出す内部関数（read-only）。
# 高速化: 追加 worktree が無ければ gh を叩かず即 return。gh は repo 毎に 1 回だけ。
# NOTE: zsh の `path` は $PATH 連動の特殊配列。local 名に使わないこと（wtpath を使う）。
__wgs_scan_repo() {
  emulate -L zsh
  local repo=$1 line wtpath branch main_wt porc
  porc=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || return 0
  main_wt=$(print -r -- "$porc" | awk '/^worktree /{print $2; exit}')
  local -a wpaths wbranches
  wtpath="" branch=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wtpath="${line#worktree }" ;;
      branch\ *)   branch="${line#branch refs/heads/}"
        [[ "$wtpath" != "$main_wt" ]] && { wpaths+=("$wtpath"); wbranches+=("$branch"); } ;;
      "") wtpath="" branch="" ;;
    esac
  done <<< "$porc"
  (( ${#wbranches} )) || return 0   # 追加 worktree 無し → gh 不要（大半の repo をここで足切り）

  # gh pr list を 1 回。branch→最優先 state（OPEN>MERGED>CLOSED）に集約。
  typeset -A st; typeset -A rank=(OPEN 3 MERGED 2 CLOSED 1)
  local br stt out rc
  out=$(cd "$repo" && gh pr list --state all --limit "${WGS_LIMIT:-500}" \
          --json headRefName,state --jq '.[]|[.headRefName,.state]|@tsv' 2>/dev/null)
  rc=$?
  if (( rc != 0 )); then
    print -r -- "wgs: gh 失敗のためスキップ: $repo" >&2
    return 0
  fi
  while IFS=$'\t' read -r br stt; do
    [[ -z "$br" ]] && continue
    (( ${rank[$stt]:-0} > ${rank[${st[$br]:-_}]:-0} )) && st[$br]=$stt
  done <<< "$out"

  local i
  for (( i=1; i<=${#wbranches}; i++ )); do
    br=${wbranches[i]}; stt=${st[$br]:-NO-PR}
    [[ "$stt" == MERGED || "$stt" == NO-PR ]] && \
      print -r -- "${stt}"$'\t'"${repo:t}"$'\t'"${br}"$'\t'"${wpaths[i]}"
  done
}

# wgs (worktree garbage search): 複数リポジトリを横断し、wrm と同条件
# （PR が MERGED / PR 無し）の worktree を検索して一覧表示する（read-only, 削除はしない）。
#   使い方: wgs [root ...]   （既定 root: ~/git_clone）
# 依存: git, gh, awk。掃除は各 repo に cd して wrm。
wgs() {
  emulate -L zsh
  local -a roots; roots=("$@"); (( ${#roots} )) || roots=(~/git_clone)
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh 未認証のため中止。'gh auth login' を。" >&2; return 1
  fi
  local -a repos
  repos=("${(@f)$(find "${roots[@]}" -maxdepth 6 -type d -name .git -prune 2>/dev/null)}")
  repos=("${repos[@]:h}")   # .git → repo ディレクトリ
  (( ${#repos} )) || { echo "リポジトリが見つかりません: ${roots[*]}"; return 0; }

  # pass1（ローカル・高速）: 追加 worktree を持つ repo だけ抽出。gh を叩くのはこの少数のみ。
  # こうして遅い gh repo だけを並列波に集約し、fast repo との混在によるバリア待ちを無くす。
  local repo; local -a todo
  for repo in "${repos[@]}"; do
    (( $(git -C "$repo" worktree list --porcelain 2>/dev/null | grep -c '^worktree ') > 1 )) \
      && todo+=("$repo")
  done

  local results=""
  if (( ${#todo} )); then
    # pass2: todo だけを max 並列でスキャン（チャンク境界で wait、出力は repo 毎に別ファイル）。
    local tmp; tmp=$(mktemp -d) || return 1
    local max=${WGS_MAX:-8} i=1 j
    while (( i <= ${#todo} )); do
      for (( j=i; j < i+max && j <= ${#todo}; j++ )); do
        __wgs_scan_repo "${todo[j]}" > "$tmp/$j" &
      done
      wait
      (( i += max ))
    done
    results=$(cat "$tmp"/* 2>/dev/null | sort)
    rm -rf "$tmp"
  fi
  if [[ -z "$results" ]]; then
    echo "garbage worktree はありません。(${#repos} repos を検索)"
    return 0
  fi
  local n; n=$(print -r -- "$results" | grep -c .)
  { print -r -- "STATE"$'\t'"REPO"$'\t'"BRANCH"$'\t'"PATH"; print -r -- "$results"; } \
    | column -t -s $'\t'
  echo "---"
  echo "合計 ${n} 件 / 検索 ${#repos} repos（うち worktree 有り ${#todo} で gh 照会）。掃除は各 repo に cd して wrm。"
}
