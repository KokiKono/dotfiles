#!/usr/bin/env zsh
# 自分にアサインされた open issue を org 横断で探し、
# "URL<TAB>リポジトリ<TAB>番号<TAB>タイトル" の TSV で吐く。
# pick.zsh から直接と、fzf の reload バインド（再取得）から呼ばれる。
#
# pick.zsh に inline せず別ファイルにしてあるのは、fzf の --bind が **コンマで
# バインドを区切る**ため。jq のフィルタをそのまま reload() に埋めると、中のコンマが
# 区切りとして食われて fzf が起動時に `bind action not specified` で落ちる。
#
# 1 列目を URL にしてあるのは、issue 番号がリポジトリ間で一意でないため。
# hello-run には URL を渡す（hello-run 側が URL を解釈する）。
# 対象 org は環境変数で受け取る（pick.zsh が export する）。
emulate -L zsh
setopt pipe_fail

[[ -n ${HELLO_RUN_ISSUE_ORG:-} ]] || { print -ru2 -- "HELLO_RUN_ISSUE_ORG が未設定"; exit 2 }

# gh issue list はリポジトリ単位なので、org 横断には gh search issues を使う。
gh search issues \
  --owner "$HELLO_RUN_ISSUE_ORG" \
  --assignee @me \
  --state open \
  --sort updated \
  --limit "${HELLO_RUN_LIMIT:-100}" \
  --json url,repository,number,title \
  | jq -r '.[] | [.url, .repository.name, (.number|tostring), .title] | @tsv'
