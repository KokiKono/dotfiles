<!-- hello-run が新しいタブの claude に最初に送るプロンプト。
     ここを書き換えれば次回から反映される（chezmoi apply は要る）。

     使える差し込み:
       {{issue_url}}     https://github.com/<org>/<repo>/issues/<N>
       {{issue_repo}}    <org>/<repo>
       {{issue_number}}  <N>
       {{issue_title}}   issue のタイトル（取れなければ空）
       {{branch}}        作ったブランチ名
       {{repos}}         worktree を作ったリポジトリ名（空白区切り）
       {{session_dir}}   claude の cwd（<root>/.sessions/issue-<N>）

     HTML コメントの行は送られない（この注意書き自体がそれ）。
     改行は空白1つに畳んでから送る（claude の入力欄で途中送信にならないようにするため）。

     このリポジトリは PUBLIC なので、勤務先の org 名・リポジトリ名をここに直接書かない。
     リポジトリ名は {{repos}} で差し込む（実体は ~/.pzshrc の HELLO_RUN_REPOS）。 -->

{{issue_url}} に取り組みます。
カレントディレクトリ直下に {{repos}} の worktree（ブランチ {{branch}}）があります。まず issue の内容を確認してイシューとその周辺コード、仕様をArchifyを使って解説してブラウザで開いてください。
