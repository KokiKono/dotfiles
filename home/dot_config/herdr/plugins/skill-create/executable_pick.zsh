#!/usr/bin/env zsh
# kokikono.skill-create の中身。作りたいスキルを書かせ、dotfiles の worktree と
# herdr のタブを用意して claude を起動し、prompt.md を送る。
# herdr から popup として起動される（argv は herdr-plugin.toml を参照）。
#
# PR・マージ・chezmoi apply をここで直接やらないのは、スキルの中身が決まるまで
# スキル名も PR 本文も決まらないため。そこから先は claude に任せる。
emulate -L zsh
setopt pipe_fail

source "${0:A:h}/lib.zsh"

typeset -a missing
for c in git wt gh jq herdr chezmoi claude; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
(( ${#missing} )) && sc_die "未インストール: ${missing[*]}"

[[ -r $SKILL_CREATE_HELLO_RUN ]] \
  || sc_die "hello-run.zsh が見つかりません: $SKILL_CREATE_HELLO_RUN（chezmoi apply 済みか確認）"
source "$SKILL_CREATE_HELLO_RUN"

typeset repo base
repo=$(sc_source_repo) || sc_die "chezmoi のソース（dotfiles リポジトリ）を特定できません"

typeset tmpd
tmpd=$(mktemp -d) || sc_die "一時ディレクトリを作れません"
trap 'rm -rf "$tmpd"' EXIT

# 1. 作りたいもの。空で閉じたら黙って popup を閉じる
typeset task
task=$(sc_read_task "$tmpd/task.md") || exit 0

# 2. ブランチ名。wt と同じく母体が最後に pull された時点から切らないよう、先に fetch する
print -r -- "fetch: ${repo:t}"
git -C "$repo" fetch --prune origin || sc_die "git fetch に失敗しました: $repo"
base=$(__hr_default_branch "$repo") || sc_die "デフォルトブランチを特定できません: $repo"

typeset slug branch
print -r -- "slug を推定しています…"
slug=$(__hr_slugify "$task") || slug=$(date +%Y%m%d-%H%M%S)
branch=$(sc_unique_branch "$repo" "$slug")
print -r -- "branch: $branch"

# 3. worktree。置き場は wt の設定に任せる（手で切る worktree と同じ場所に並ぶ）
command wt -C "$repo" -y switch --no-cd --create "$branch" --base "origin/$base" \
  || sc_die "worktree の作成に失敗しました: $branch"
typeset wtdir
wtdir=$(sc_worktree_of "$repo" "$branch") || sc_die "作った worktree が見つかりません: $branch"
print -r -- "worktree: $wtdir"

# 4. タブ。ペインは 1 枚で足りる（触るのは dotfiles だけ）
typeset ws created tab_id pane label="skill-${branch#skills/}"
ws=$(__hz_workspace_id) || sc_die "workspace を特定できません（herdr 環境か確認）"
created=$(herdr tab create --workspace "$ws" --label "$label" --cwd "$wtdir" --no-focus) \
  || sc_die "タブの作成に失敗しました"
tab_id=$(print -r -- "$created" | jq -r '.result.tab.tab_id')
pane=$(print -r -- "$created" | jq -r '.result.root_pane.pane_id')
[[ -n $tab_id && $tab_id != null && -n $pane && $pane != null ]] \
  || sc_die "タブの作成結果を読めません: $created"

# 5. claude を起動し、信頼確認ダイアログを操作できるよう先にタブへ移ってから送る
print -r -- "claude を起動しています…"
__hr_start_agent "$label" "$pane" 0 || sc_die "claude の起動に失敗しました（タブは作成済み: $label）"
herdr tab focus "$tab_id" >/dev/null

typeset text
text=$(sc_render_prompt "$task" "$branch" "$wtdir" "$repo" "$base")
__hr_send_prompt "$label" "$text" \
  || sc_die "初期プロンプトを送れませんでした。claude が入力待ちになったら以下を貼ってください:"$'\n'"$text"
exit 0
