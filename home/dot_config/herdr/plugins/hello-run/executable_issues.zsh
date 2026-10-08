#!/usr/bin/env zsh
# 自分にアサインされた open issue を "番号<TAB>タイトル" の TSV で吐く。
# pick.zsh から直接と、fzf の reload バインド（再取得）から呼ばれる。
#
# pick.zsh に inline せず別ファイルにしてあるのは、fzf の --bind が **コンマで
# バインドを区切る**ため。jq のフィルタをそのまま reload() に埋めると、中のコンマが
# 区切りとして食われて fzf が起動時に `bind action not specified` で落ちる。
# 対象リポジトリは環境変数で受け取る（pick.zsh が export する）。
emulate -L zsh
setopt pipe_fail

[[ -n ${HELLO_RUN_ISSUE_REPO:-} ]] || { print -ru2 -- "HELLO_RUN_ISSUE_REPO が未設定"; exit 2 }

gh issue list \
  --repo "$HELLO_RUN_ISSUE_REPO" \
  --state open \
  --limit "${HELLO_RUN_LIMIT:-100}" \
  --assignee @me \
  --json number,title \
  | jq -r '.[] | [(.number|tostring), .title] | @tsv'
