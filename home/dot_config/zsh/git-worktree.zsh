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

# __gwt_pr_states <repo>: そのリポジトリの PR を 1 回の `gh pr list` でまとめて取得し、
# `branch \t state` を stdout に出す。同一ブランチに複数 PR がある場合は
# OPEN > MERGED > CLOSED の優先度で 1 つに集約する（OPEN を取りこぼすと誤削除になるため）。
# gh 失敗時は非 0 を返す（呼び出し側が「PR 無し」と誤認しないように）。
# 件数上限は GWT_PR_LIMIT（既存の WGS_LIMIT も後方互換で参照）。
__gwt_pr_states() {
  emulate -L zsh
  local repo=$1 out br stt
  out=$(cd "$repo" && gh pr list --state all --limit "${GWT_PR_LIMIT:-${WGS_LIMIT:-500}}" \
          --json headRefName,state --jq '.[]|[.headRefName,.state]|@tsv' 2>/dev/null) || return 1
  typeset -A st; typeset -A rank=(OPEN 3 MERGED 2 CLOSED 1)
  while IFS=$'\t' read -r br stt; do
    [[ -z "$br" ]] && continue
    (( ${rank[$stt]:-0} > ${rank[${st[$br]:-_}]:-0} )) && st[$br]=$stt
  done <<< "$out"
  for br in ${(k)st}; do print -r -- "$br"$'\t'"${st[$br]}"; done
}

# wrm: PR が MERGED（または PR 無し）の worktree を fzf で選んで削除
#   既定では候補を全選択済みの fzf に出す（Tab で選択切替 / Enter で確定 / Esc で中止）。
#   削除は 1 件ごとに [n/N] の進捗行 + 末尾に集計。未コミット変更などで失敗した分は
#   そのまま再選択 UI に出し、--force で削除し直せる。
#   -f, --force : git worktree remove を --force で実行（変更/未追跡ファイル込みで削除）
#   -a, --all   : fzf を使わず全候補を対象にする（-f 無しなら y/N 確認あり）
wrm() {
  emulate -L zsh
  local force=0 all=0 arg
  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=1 ;;
      -a|--all)   all=1 ;;
      -h|--help)  echo "usage: wrm [-f|--force] [-a|--all]"; return 0 ;;
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
  local current main_wt line wtpath branch state; local -a candidates wpaths wbranches
  current=$(git rev-parse --show-toplevel 2>/dev/null)
  main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wtpath="${line#worktree }" ;;
      branch\ *)   branch="${line#branch refs/heads/}"
        [[ "$wtpath" != "$current" && "$wtpath" != "$main_wt" ]] && \
          { wpaths+=("$wtpath"); wbranches+=("$branch"); } ;;
      "") wtpath=""; branch="" ;;
    esac
  done < <(git worktree list --porcelain)
  if (( ${#wbranches} )); then
    # gh 呼び出しは repo 全体で 1 回（旧実装は worktree 毎に問い合わせて N 往復していた）。
    local pr_out
    pr_out=$(__gwt_pr_states "${current:-$PWD}") \
      || { echo "wrm: gh pr list に失敗しました。中止。" >&2; return 1; }
    # NOTE: ここの変数名は下の表組みで使う i/st/br/pt と重ねないこと。
    # zsh は同一スコープで既存の local を `local` し直すと中身を stdout に出力する。
    typeset -A prstate; local k pbr pst
    while IFS=$'\t' read -r pbr pst; do
      [[ -n "$pbr" ]] && prstate[$pbr]=$pst
    done <<< "$pr_out"
    for (( k=1; k<=${#wbranches}; k++ )); do
      state=${prstate[${wbranches[k]}]:-NO-PR}
      [[ "$state" == MERGED || "$state" == NO-PR ]] && \
        candidates+=("${wpaths[k]}"$'\t'"${wbranches[k]}"$'\t'"$state")
    done
  fi
  (( ${#candidates[@]} == 0 )) && { echo "削除対象の worktree はありません。"; return 0; }

  # 表示用テーブル（STATE / BRANCH / PATH を桁揃え）。
  # 各行は `idx \t state \t branch \t path \t 整形済み文字列`。fzf には最後の列だけ見せ、
  # 選択結果は idx で元データに引き当てる（path に空白があっても安全）。
  local i st br pt w1=5 w2=6
  for (( i=1; i<=${#candidates[@]}; i++ )); do
    br="${${candidates[i]#*$'\t'}%%$'\t'*}"; st="${candidates[i]##*$'\t'}"
    (( ${#st} > w1 )) && w1=${#st}
    (( ${#br} > w2 )) && w2=${#br}
  done
  local hdr; hdr=$(printf '%-*s  %-*s  %s' $w1 STATE $w2 BRANCH PATH)
  local -a rows disp
  local row
  for (( i=1; i<=${#candidates[@]}; i++ )); do
    pt="${candidates[i]%%$'\t'*}"
    br="${${candidates[i]#*$'\t'}%%$'\t'*}"; st="${candidates[i]##*$'\t'}"
    row=$(printf '%-*s  %-*s  %s' $w1 "$st" $w2 "$br" "$pt")
    disp+=("$row")
    rows+=("$i"$'\t'"$st"$'\t'"$br"$'\t'"$pt"$'\t'"$row")
  done

  local -a picked
  if (( ! all )) && command -v fzf >/dev/null 2>&1; then
    local selected
    selected=$(printf '%s\n' "${rows[@]}" | fzf --multi --ansi --delimiter=$'\t' --with-nth=5 \
      --bind 'start:select-all' \
      --header="$hdr"$'\n'"Tab:選択切替 / Ctrl-A:全選択 / Enter:削除実行 / Esc:中止" \
      --bind 'ctrl-a:select-all' --bind 'ctrl-d:deselect-all' \
      --preview-window=right:55% \
      --preview 'git -C {4} status --short --branch 2>/dev/null; echo; git -C {4} log --oneline -20 --color=always {3} 2>/dev/null')
    [[ -z "$selected" ]] && { echo "中止。"; return 1; }
    picked=("${(@f)$(print -r -- "$selected" | cut -f1)}")
  else
    echo "以下の worktree を削除します:"
    printf '  %s\n' "$hdr" "${disp[@]}"
    if (( force )); then
      echo "--force: 確認を省略して削除します。"
    else
      echo -n "続行しますか？ [y/N] "; local ans; read -r ans
      [[ "$ans" == [yY] ]] || { echo "中止。"; return 1; }
    fi
    picked=({1..${#candidates[@]}})
  fi

  # 削除実行。entry は `path \t branch`。
  # NOTE: 変数名は上の表組み（i/st/br/pt/w1/w2）と重ねないこと。zsh は同一スコープで
  # 既存の local を `local` し直すと中身を stdout に出力する。
  local -a entries
  for i in "${picked[@]}"; do
    [[ -z "$i" ]] && continue
    entries+=("${candidates[i]%%$'\t'*}"$'\t'"${${candidates[i]#*$'\t'}%%$'\t'*}")
  done
  (( ${#entries[@]} == 0 )) && { echo "中止。"; return 1; }
  __gwt_remove_worktrees $force "${entries[@]}" && return 0

  # ここから失敗リカバリ。--force で実行済みなら再試行しても無駄なので抜ける。
  local -a failed=("${__gwt_failed[@]}")
  (( force )) && return 1
  (( ${#failed[@]} == 0 )) && return 1
  __gwt_retry_force $all "${failed[@]}"
}

# __gwt_remove_worktrees <force> <entry...>   entry = `path \t branch`
# 1 件ごとに [n/N] の進捗行を出し、最後に集計を出す。途中で失敗しても止めず、
# 失敗理由（git のエラー）を 1 行に畳んで添える。失敗した entry は配列
# __gwt_failed に残す（呼び出し側の --force 再試行で使う）。全部成功なら 0。
__gwt_remove_worktrees() {
  emulate -L zsh
  local force=$1; shift
  local -a entries=("$@") rm_opts
  (( force )) && rm_opts=(--force)
  typeset -ga __gwt_failed; __gwt_failed=()
  local total=${#entries[@]} n=0 ok=0 ng=0 bw=0 e wtpath branch rmerr
  for e in "${entries[@]}"; do
    branch="${e#*$'\t'}"; (( ${#branch} > bw )) && bw=${#branch}
  done
  for e in "${entries[@]}"; do
    wtpath="${e%%$'\t'*}"; branch="${e#*$'\t'}"
    (( ++n ))
    if rmerr=$(git worktree remove "${rm_opts[@]}" "$wtpath" 2>&1); then
      (( ++ok ))
      printf '[%d/%d] ✔ %-*s (%s)\n' $n $total $bw "$branch" "${wtpath/#$HOME/~}"
    else
      (( ++ng )); __gwt_failed+=("$e")
      printf '[%d/%d] ✘ %-*s (%s)\n' $n $total $bw "$branch" "${wtpath/#$HOME/~}"
      [[ -n "$rmerr" ]] && print -r -- "      → ${rmerr//$'\n'/ }"
    fi
  done
  printf -- '---\n削除 %d 件 / 失敗 %d 件 (計 %d 件)\n' $ok $ng $total
  (( ng == 0 ))
}

# __gwt_retry_force <all> <entry...>: 失敗した worktree を再選択し --force で削除し直す。
# fzf があれば全選択済みの fzf（Esc で中止）、all=1 や fzf 無し・非 tty なら y/N 確認。
__gwt_retry_force() {
  emulate -L zsh
  local all=$1; shift
  local -a failed=("$@") retry rrows
  local fi fbr fpt fw=6 fsel fk
  for fi in "${failed[@]}"; do
    fbr="${fi#*$'\t'}"; (( ${#fbr} > fw )) && fw=${#fbr}
  done
  for (( fk=1; fk<=${#failed[@]}; fk++ )); do
    fpt="${failed[fk]%%$'\t'*}"; fbr="${failed[fk]#*$'\t'}"
    rrows+=("$fk"$'\t'"$fbr"$'\t'"$fpt"$'\t'"$(printf '%-*s  %s' $fw "$fbr" "${fpt/#$HOME/~}")")
  done
  echo
  if (( ! all )) && command -v fzf >/dev/null 2>&1 && [[ -t 0 ]]; then
    fsel=$(printf '%s\n' "${rrows[@]}" | fzf --multi --ansi --delimiter=$'\t' --with-nth=4 \
      --bind 'start:select-all' --bind 'ctrl-a:select-all' --bind 'ctrl-d:deselect-all' \
      --header="$(printf '%-*s  %s' $fw BRANCH PATH)"$'\n'"失敗分を --force で再削除 / Tab:選択切替 / Enter:実行 / Esc:中止" \
      --preview-window=right:55% \
      --preview 'git -C {3} status --short --branch 2>/dev/null; echo; git -C {3} status --porcelain 2>/dev/null')
    [[ -z "$fsel" ]] && { echo "再試行を中止。"; return 1; }
    for fk in "${(@f)$(print -r -- "$fsel" | cut -f1)}"; do
      [[ -n "$fk" ]] && retry+=("${failed[fk]}")
    done
  else
    echo "以下を --force で再削除します（未コミットの変更ごと消えます）:"
    for fi in "${rrows[@]}"; do print -r -- "  ${fi##*$'\t'}"; done
    echo -n "続行しますか？ [y/N] "; local fans; read -r fans
    [[ "$fans" == [yY] ]] || { echo "再試行を中止。"; return 1; }
    retry=("${failed[@]}")
  fi
  (( ${#retry[@]} == 0 )) && { echo "再試行を中止。"; return 1; }
  echo "--force で再削除します:"
  __gwt_remove_worktrees 1 "${retry[@]}"
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

  # gh は repo 毎に 1 回（wrm と共通の __gwt_pr_states）。
  typeset -A st; local br stt out
  out=$(__gwt_pr_states "$repo") || {
    print -r -- "wgs: gh 失敗のためスキップ: $repo" >&2
    return 0
  }
  while IFS=$'\t' read -r br stt; do
    [[ -n "$br" ]] && st[$br]=$stt
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
