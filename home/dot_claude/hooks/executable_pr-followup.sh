#!/bin/bash
# gh pr create が PR を作ったら、続けて /pr-followup を回すよう Claude に伝える。
# hook からスキルは起動できないので、PostToolUse の additionalContext で指示するだけにする。
# Stop を止めて最後まで回させることはしない（人に聞くべき場面でも止まれなくなるため）
set -euo pipefail

input=$(cat)

# Bash の呼び出しごとに走るので、関係ないコマンドは外部プロセスを起動せずに抜ける
[[ $input == *'gh pr create'* ]] || exit 0

[ "${SKIP_PR_FOLLOWUP:-}" = "1" ] && exit 0

# 1 行目がコマンド（改行は ; に畳む）、2 行目以降が stdout
{
  IFS= read -r command
  stdout=$(cat)
} < <(jq -r '(.tool_input.command // "" | gsub("\n"; ";")), (.tool_response.stdout // "")' <<<"$input")

source "$(dirname "${BASH_SOURCE[0]}")/lib/gh-pr-create.sh"
[[ $command =~ $GH_PR_CREATE_RE ]] || exit 0

# 失敗したとき（既に PR がある等）は URL が stdout に出ないので、何もしない
url=$(grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' <<<"$stdout" | tail -n 1) || exit 0

jq -n --arg url "$url" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "PR を作成しました（\($url)）。続けて Skill ツールで pr-followup を引数 \($url) で実行し、CI・i18n の警告・claude-review の指摘が無くなるまで対応してください。"
  },
  systemMessage: "pr-followup で \($url) のフォローを始めます"
}'
