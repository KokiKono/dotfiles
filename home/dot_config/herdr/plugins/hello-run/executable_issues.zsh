#!/usr/bin/env zsh
# issue 一覧を "番号<TAB>タイトル<TAB>担当" の TSV で吐く。pick.zsh から直接と、
# fzf の reload バインドから呼ばれる。
#
# pick.zsh に inline せず別ファイルにしてあるのは、fzf の --bind が **コンマで
# バインドを区切る**ため。jq のフィルタをそのまま reload() に埋めると、中のコンマが
# 区切りとして食われて fzf が起動時に `bind action not specified` で落ちる。
# 対象リポジトリは環境変数で受け取る（pick.zsh が export する）。
emulate -L zsh
setopt pipe_fail

case ${1-} in
  mine) scope=(--assignee @me) ;;
  all)  scope=() ;;
  *)    print -ru2 -- "usage: issues.zsh <mine|all>"; exit 2 ;;
esac

[[ -n ${HELLO_RUN_ISSUE_REPO:-} ]] || { print -ru2 -- "HELLO_RUN_ISSUE_REPO が未設定"; exit 2 }

gh issue list \
  --repo "$HELLO_RUN_ISSUE_REPO" \
  --state open \
  --limit "${HELLO_RUN_LIMIT:-100}" \
  "${scope[@]}" \
  --json number,title,assignees \
  | jq -r '.[] | [(.number|tostring), .title, (.assignees|map(.login)|join(",")|if . == "" then "-" else . end)] | @tsv'
