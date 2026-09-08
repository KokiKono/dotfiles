#!/bin/bash
set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')

# gh pr create コマンドのみインターセプト
if ! echo "$command" | grep -q 'gh pr create'; then
  exit 0
fi

# トランスクリプトでsimplifyスキルの実行確認
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  if grep -qi 'simplify' "$transcript_path" 2>/dev/null; then
    exit 0  # review済み → 通過
  fi
fi

# review未実施 → ブロック
jq -n '{
  hookSpecificOutput: {permissionDecision: "deny"},
  systemMessage: "PRを作成する前に /simplify スキルを実行してコードをレビューし、必要な修正を完了してください。その後、再度PRを作成してください。"
}'
exit 0
