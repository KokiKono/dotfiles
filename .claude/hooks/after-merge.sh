#!/bin/bash
# このリポジトリで Claude が gh pr merge を実行したら、apply-merged スキルで $HOME に反映させる。
# PostToolUse は成功した呼び出しにだけ届くので、出力の文言は見ない。
set -euo pipefail

input=$(cat)
[[ $input == *'gh pr merge'* ]] || exit 0

command=$(jq -r '.tool_input.command // "" | gsub("\n"; ";")' <<<"$input")
[[ $command =~ (^|[;&|])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]] || exit 0
# --auto はまだマージしていない。別のリポジトリの PR は apply の対象ではない
[[ $command =~ [[:space:]](--auto|--repo|-R)([[:space:]=]|$) ]] && exit 0

rest=${command#*gh pr merge}
# 件名や本文の数字（--subject "Fix 12"）を PR 番号と取り違えないよう、引用と値を取るフラグを先に外す
rest=$(sed -E "s/'[^']*'/Q/g; s/\"[^\"]*\"/Q/g; s/(^|[[:space:]])(-[tbFA]|--(subject|body|body-file|author-email|match-head-commit))([[:space:]]+|=)[^[:space:]]+//g" <<<"$rest")
pr=$(grep -oE '(^|[[:space:]])(https://[^[:space:]]+/pull/[0-9]+|[0-9]+)([[:space:]]|$)' <<<"$rest" | head -1 | tr -d '[:space:]' || true)
pr=${pr##*/}

jq -n --arg pr "$pr" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("PR をマージしました。続けて Skill ツールで apply-merged を"
      + (if $pr == "" then "（PR 番号は gh pr view で確かめて）" else "引数 \($pr) で" end)
      + "実行し、変更を $HOME に反映してください。")
  }
}'
