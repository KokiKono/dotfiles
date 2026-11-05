<!-- skill-create プラグインが新しいタブの claude に最初に送るプロンプト。
     ここを書き換えれば次回から反映される（chezmoi apply は要る）。

     使える差し込み:
       {{task}}            popup で書いた「作りたいスキル」（改行は空白に畳まれる）
       {{branch}}          作ったブランチ名（skills/<slug>）
       {{worktree}}        claude の cwd になる worktree
       {{source_repo}}     chezmoi のソース（PR をマージしたあと pull するチェックアウト）
       {{default_branch}}  マージ先のブランチ

     HTML コメントの行は送られない（この注意書き自体がそれ）。
     改行は空白1つに畳んでから送る（claude の入力欄で途中送信にならないようにするため）。

     apply をスキルのディレクトリに絞っているのは、素の chezmoi apply だと
     アプリが書き換えた ~/.claude/settings.json などを追跡側の内容で潰すため。 -->

dotfiles リポジトリに新しいスキルを足します。作りたいもの: {{task}}
カレントディレクトリは worktree（ブランチ {{branch}}）です。次の順に進めてください。
1. skill-creator:skill-creator スキルを使ってスキルを作る。置き場は home/dot_claude/skills/<スキル名>/。CLAUDE.md の規約に従い、自作スキルの一覧と tests/files/apply.bats の配備検査も更新する。このリポジトリは PUBLIC なので、勤務先の社名・org 名・リポジトリ名をスキルに書かない。
2. bats -r tests/ が通ることを確かめる。
3. コミットして push し、gh pr create で PR を作る。
4. gh pr checks --watch で CI の完了を待ち、通ったら gh pr merge --merge でマージする。落ちたら直して push し直す。
5. {{source_repo}} が {{default_branch}} をチェックアウトしていて未コミットの変更が無いことを確かめてから git pull --ff-only し、chezmoi apply ~/.claude/skills/<スキル名> でローカルに反映する。条件を満たさなければ pull も apply もせずに報告する。
