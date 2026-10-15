<!-- hello-run --scratch が新しいタブの claude に最初に送るプロンプト。
     issue を起票していない作業用で、issue 版は prompt.md のほう。
     ここを書き換えれば次回から反映される（chezmoi apply は要る）。

     使える差し込み:
       {{task}}         エディタに書いた「やりたいこと」（改行は空白に畳まれる）
       {{readme}}       それを書き出した README.md のパス
       {{branch}}       作ったブランチ名
       {{repos}}        worktree を作ったリポジトリ名（空白区切り）
       {{session_dir}}  claude の cwd（<root>/.sessions/scratch-<slug>）

     HTML コメントの行は送られない（この注意書き自体がそれ）。
     改行は空白1つに畳んでから送る（claude の入力欄で途中送信にならないようにするため）。

     このリポジトリは PUBLIC なので、勤務先の org 名・リポジトリ名をここに直接書かない。
     リポジトリ名は {{repos}} で差し込む（実体は ~/.pzshrc の HELLO_RUN_REPOS）。 -->

カレントディレクトリ直下の README.md に今回やりたいことを書きました。
同じ階層に {{repos}} の worktree（ブランチ {{branch}}）があります。まず README.md を読んで、関連するコードと仕様を Archify を使って解説してブラウザで開いてください。
