# kokikono.skill-create の中身のうち、herdr を触らない部分。pick.zsh が source し、
# テストもここを直接叩く。
#
# プロンプトのテンプレート処理と slug 推定は hello-run と同じものを使う
# （HTML コメントを落とす・改行を畳む、の規則を 2 か所に持たないため）。

SKILL_CREATE_HELLO_RUN="${SKILL_CREATE_HELLO_RUN:-$HOME/.config/zsh/hello-run.zsh}"
SKILL_CREATE_PROMPT_FILE="${SKILL_CREATE_PROMPT_FILE:-${0:A:h}/prompt.md}"
SKILL_CREATE_FAIL_WAIT="${SKILL_CREATE_FAIL_WAIT:-1}"

# popup はコマンドが終了した瞬間に閉じる。理由を読む時間が無くなるので失敗時だけ待つ。
sc_die() {
  print -ru2 -- "skill-create: $*"
  if [[ -t 0 && $SKILL_CREATE_FAIL_WAIT == 1 ]]; then
    print -rn -- $'\n  何かキーを押すと閉じます '
    read -k 1
  fi
  exit 1
}

# sc_source_repo → dotfiles のチェックアウト（chezmoi のソースを持つリポジトリ）。
# マージ後に pull して apply するのはこのチェックアウトなので、worktree の母体もここにする。
# chezmoi source-path は .chezmoiroot 込みの home/ を返すので、git に上まで辿らせる。
sc_source_repo() {
  emulate -L zsh
  local src=${SKILL_CREATE_REPO:-}
  if [[ -z $src ]]; then
    command -v chezmoi >/dev/null 2>&1 || return 1
    src=$(chezmoi source-path 2>/dev/null) || return 1
  fi
  git -C "$src" rev-parse --show-toplevel 2>/dev/null
}

# sc_unique_branch <repo> <slug> → 既存と衝突しないブランチ名（skills/<slug>, -2, -3 …）。
# 呼ぶ前に fetch しておくこと。マージ済みのブランチが残っていても、それに合流させると
# 前のスキルの履歴の上に積むことになるので、名前をずらして新しく切る。
sc_unique_branch() {
  emulate -L zsh
  local repo=$1 slug=$2 try=$2
  integer n=1
  while git -C "$repo" show-ref --quiet --verify "refs/heads/skills/$try" \
     || git -C "$repo" show-ref --quiet --verify "refs/remotes/origin/skills/$try"; do
    (( n++ ))
    try="$slug-$n"
  done
  print -r -- "skills/$try"
}

# sc_worktree_of <repo> <branch> → そのブランチをチェックアウトしている worktree のパス。
# wt の置き場は設定次第（既定は兄弟の <repo>.<branch>）なので、決め打ちせず git に訊く。
sc_worktree_of() {
  emulate -L zsh
  local repo=$1 branch=$2 line wtpath=
  while IFS= read -r line; do
    case $line in
      'worktree '*) wtpath=${line#worktree } ;;
      "branch refs/heads/$branch") print -r -- "$wtpath"; return 0 ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  return 1
}

# sc_read_task <file>: $EDITOR で「作りたいスキル」を書かせて中身を出す（空なら非 0）。
# hello-run の __hr_read_task は雛形の文面が README 前提なので使わない。
sc_read_task() {
  emulate -L zsh
  local file=$1 editor=${EDITOR:-hx} body
  cat >"$file" <<'EOF'
<!-- 作りたいスキルを書いて保存する（このコメントは送られない）。
     何をするスキルか、どんなときに発火してほしいかを書く。
     ブランチ名の slug もここから推定する。空のまま閉じると中止。 -->

EOF
  # 呼び出し側は $(...) で受けるので stdout がパイプになっている。端末へ向け直さないと
  # vim は「端末への出力ではありません」で固まり、hx は何も描かずに固まる。
  ${=editor} "$file" </dev/tty >/dev/tty || return 1
  body=$(__hr_strip_comments "$file" | sed -e '/./,$!d')
  [[ -n ${body//[[:space:]]/} ]] || return 1
  print -r -- "$body"
}

# sc_render_prompt <task> <branch> <worktree> <source_repo> <default_branch>
# テンプレートが無ければ組み込みの既定文に落ちる（chezmoi apply 前でも動くように）。
sc_render_prompt() {
  emulate -L zsh
  local body task
  body=$(__hr_template_body "$SKILL_CREATE_PROMPT_FILE") \
    || body='dotfiles リポジトリに新しいスキルを足します。作りたいもの: {{task}} カレントディレクトリは worktree（ブランチ {{branch}}）です。skill-creator:skill-creator スキルで home/dot_claude/skills/ に作り、PR を作って CI が通ったらマージし、{{source_repo}} を {{default_branch}} に pull してから chezmoi apply ~/.claude/skills/<スキル名> で反映してください。'
  # テンプレートと同じく、書いた内容の改行も畳む
  task=${(j: :)${=1}}
  body=${body//\{\{task\}\}/$task}
  body=${body//\{\{branch\}\}/$2}
  body=${body//\{\{worktree\}\}/$3}
  body=${body//\{\{source_repo\}\}/$4}
  body=${body//\{\{default_branch\}\}/$5}
  print -r -- "$body"
}
