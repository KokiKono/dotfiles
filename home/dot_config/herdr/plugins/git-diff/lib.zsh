# kokikono.git-diff の共有部分。pick.zsh / files.zsh / show.zsh が source する。
#
# 見せる差分は「PR に載る差分 + 未コミット」= merge-base(origin/<default>, HEAD) と
# ワーキングツリーの差分。PR を作る直前に「これで出すぞ」を確かめるのが用途なので、
# コミット済みだけに絞らない。

GD_FAIL_WAIT="${GD_FAIL_WAIT:-1}"

# popup はコマンドが終了した瞬間に閉じる。理由を読む時間が無くなるので失敗時だけ待つ。
gd_die() {
  print -ru2 -- "git-diff: $*"
  if [[ -t 0 && $GD_FAIL_WAIT == 1 ]]; then
    print -rn -- $'\n  何かキーを押すと閉じます '
    read -k 1
  fi
  exit 1
}

# 作業中のリポジトリ。popup は元のペインとは別プロセスで cwd を引き継がない。
# herdr はプラグインの pane に HERDR_PLUGIN_CONTEXT_JSON を渡してきて、その中に
# popup を開いた時点のフォーカス中ペインの cwd が入っているので、まずそれを見る。
# 無ければ herdr に訊き（popup が開いていても focused は元のペインを指す）、
# それでも駄目なら $PWD。git リポジトリでないものは順に読み飛ばす。
gd_repo_dir() {
  local -a candidates
  [[ -n ${GIT_DIFF_REPO:-} ]] && candidates+=("$GIT_DIFF_REPO")
  if [[ -z ${GIT_DIFF_REPO:-} ]] && command -v jq >/dev/null 2>&1; then
    [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] && candidates+=(${(f)"$(
      print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" \
        | jq -r '[.focused_pane_cwd, .workspace_cwd] | map(select(. != null and . != "")) | .[]' 2>/dev/null
    )"})
    local listed
    if command -v herdr >/dev/null 2>&1; then
      listed=$(herdr pane list 2>/dev/null) && candidates+=(${(f)"$(
        print -r -- "$listed" | jq -r '[.result.panes[]? | select(.focused) | (.foreground_cwd // .cwd)] | .[]' 2>/dev/null
      )"})
    fi
  fi
  candidates+=("$PWD")

  local dir top
  for dir in $candidates; do
    [[ -d $dir ]] || continue
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || continue
    print -r -- "$top"
    return 0
  done
  return 1
}

# origin/HEAD → main → master の順にデフォルトブランチを引く（リポジトリごとに違うため）。
gd_default_branch() {
  local repo=$1 ref b
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) \
    && { print -r -- "${ref#origin/}"; return 0 }
  for b in main master; do
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b" && { print -r -- "$b"; return 0 }
  done
  return 1
}

# 比較元。origin が無いリポジトリでは HEAD（＝未コミットだけが出る）に落とす。
# GD_BASE / GD_BASE_LABEL を設定する。
gd_resolve_base() {
  local repo=$1 def
  if def=$(gd_default_branch "$repo"); then
    GD_BASE=$(git -C "$repo" merge-base "origin/$def" HEAD 2>/dev/null)
    GD_BASE_LABEL="origin/$def"
  fi
  if [[ -z ${GD_BASE:-} ]]; then
    GD_BASE=HEAD
    GD_BASE_LABEL="HEAD（origin が無いので未コミットのみ）"
  fi
}
