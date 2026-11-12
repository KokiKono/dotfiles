#!/bin/bash
# gh pr create の前に /simplify → /code-review を済ませたかを、トランスクリプトの実際の呼び出しで確かめる。
# hook からスキルは起動できないので、足りなければ止めて Claude に実行させる。
set -euo pipefail

input=$(cat)

# Bash の呼び出しごとに走るので、関係ないコマンドは外部プロセスを起動せずに抜ける
[[ $input == *'gh pr create'* ]] || exit 0

# 区切りは空白でない文字にする（タブだと空の項目が詰められて値がずれる）。
# コマンドの改行は ; にする。空白にすると 2 行目から始まる gh pr create を見落とす
IFS=$'\x1f' read -r command cwd transcript_path < <(
  jq -r '[.tool_input.command, .cwd, .transcript_path] | map(. // "" | gsub("[\n\u001f]"; ";")) | join("\u001f")' <<<"$input"
)

source "$(dirname "${BASH_SOURCE[0]}")/lib/gh-pr-create.sh"
[[ $command =~ $GH_PR_CREATE_RE ]] || exit 0

# 急ぎのときの抜け道。コマンド文字列ではなく、ユーザーが claude を起動した環境でだけ見る
# （コマンドに書けば通るようにすると、Claude が自分で付けて飛ばせてしまう）
[ "${SKIP_PR_REVIEW:-}" = "1" ] && exit 0

# docs/ と README だけの差分はレビューを求めない。
# 拡張子で .md を丸ごと外さないのは、このリポジトリでは SKILL.md などの .md が本体だから
if [ -n "$cwd" ]; then
  base=$(git -C "$cwd" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || base=""
  for b in main master; do
    [ -n "$base" ] && break
    git -C "$cwd" show-ref -q --verify "refs/remotes/origin/$b" 2>/dev/null && base="origin/$b"
  done
  if [ -n "$base" ] && mb=$(git -C "$cwd" merge-base "$base" HEAD 2>/dev/null); then
    files=$(git -C "$cwd" diff --name-only "$mb")
    if [ -n "$files" ] && ! grep -qvE '^docs/|(^|/)README(\.[a-z]+)?$' <<<"$files"; then
      exit 0
    fi
  fi
fi

# 文字列の grep では、スキル一覧に名前が出ているだけで通ってしまう。
# Skill ツールの呼び出し（または /<name> のスラッシュコマンド）と、Edit 系の編集の位置を比べる。
# トランスクリプトは数十 MB になるので、全体を配列に読まず 1 行ずつ畳み込む。
read -r s r e < <(jq -n -r '
  reduce (inputs | [input_line_number, .]) as [$i, $rec] ({};
    ($rec.message.content // []) as $c
    | if $rec.type == "assistant" and ($c | type) == "array" then
        reduce ($c[] | select(.type == "tool_use")
                | if .name == "Skill" then (.input.skill // "") | sub("^.*:"; "")
                  elif (.name | IN("Edit", "Write", "NotebookEdit")) then "edit"
                  else empty end) as $k (.; .[$k] = $i)
      elif $rec.type == "user" then
        ([$c] | flatten | map(if type == "string" then . else (.text? // "") end) | join(" ")
         | [capture("<command-name>/?(?<k>[^<]+)</command-name>").k | sub("^.*:"; "")] | first) as $k
        # コマンド名の無い user レコード（tool_result など）で状態を空にしない
        | if $k then .[$k] = $i else . end
      else . end)
  | "\(.simplify // -1) \(.["code-review"] // -1) \(.edit // -1)"' "$transcript_path" 2>/dev/null \
  || echo "-1 -1 -1")

# /simplify はコードを書き換えるので先に、/code-review はその後かつ最後の編集より後に要る
if [ "$s" -lt 0 ]; then
  todo="/simplify で変更を整理し、続けて /code-review low でバグを確かめてください。"
elif [ "$r" -le "$s" ]; then
  todo="/simplify の後の /code-review low がまだです。実行してください。"
elif [ "$r" -le "$e" ]; then
  todo="/code-review の後にコードを編集しています。/code-review low をもう一度実行してください。"
else
  exit 0
fi

jq -n --arg msg "PRを作成する前に: ${todo} 必要な修正を終えてから、再度PRを作成してください。" '{
  hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $msg},
  systemMessage: $msg
}'
exit 0
