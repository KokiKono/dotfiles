#!/bin/bash
# レビューで繰り返す指摘を機械化した検査（kb の checks/run）を、Claude の編集・commit・PR 作成に挟む。
# - Edit / Write の後: 編集したファイルの、変えた行だけを見て、違反があれば Claude に直させる
# - git commit の前: ブランチの変更全体を見て、違反があれば commit させない
# - gh pr create の前: 同じく全体を見て、違反があれば PR を作らせない
# 検査の中身と対象リポジトリは kb が持つ（業務の知見なのでこのリポジトリには入れない）。
# 検査の無いリポジトリでは run が 2 を返すので、何もしない。
set -euo pipefail

input=$(cat)

# Bash の呼び出しごとに走るので、編集でも commit でも PR 作成でもないものは外部プロセスを起動せずに抜ける
[[ $input == *'gh pr create'* || $input == *git*commit* || $input == *'"file_path"'* ]] || exit 0
[ "${SKIP_KB_CHECKS:-}" = "1" ] && exit 0
RUN="${KB_CHECKS_RUN:-$HOME/git_clone/local/kb/checks/run}"
[ -x "$RUN" ] || exit 0

IFS=$'\x1f' read -r event tool file_path command cwd < <(
  jq -r '[.hook_event_name, .tool_name, .tool_input.file_path, .tool_input.command, .cwd]
    | map(. // "" | gsub("[\n\u001f]"; ";")) | join("\u001f")' <<<"$input"
)

# 終了コード 1（違反あり）のときだけ、その出力を返す。2（検査の無いリポジトリ）やエラーでは止めない
hits() {
  local out rc=0
  out=$("$RUN" "$@" 2>/dev/null) || rc=$?
  [ "$rc" -eq 1 ] && printf '%s' "$out"
  return 0
}

case "$event:$tool" in
  PostToolUse:Edit | PostToolUse:MultiEdit | PostToolUse:Write)
    [ -n "$file_path" ] && [ -f "$file_path" ] || exit 0
    dir=$(dirname "$file_path")
    git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
    found=$(hits --only "$file_path" "$dir")
    [ -n "$found" ] || exit 0
    # 編集は済んでいるので止められない。block の reason で Claude に違反を渡して直させる
    jq -n --arg r "レビューで繰り返し指摘されている書き方に当たりました。直してください（誤検知なら理由をユーザーに伝えてください）:
$found" '{decision: "block", reason: $r}'
    ;;
  PreToolUse:Bash)
    source "$(dirname "${BASH_SOURCE[0]}")/lib/gh-pr-create.sh"
    # git の pre-commit hook にしないのは、業務リポジトリに hook を足せず、人の commit まで止めるため。
    # Edit の後の検査は Bash（sed など）での書き換えを見ないので、commit の前にもう一度見る
    if [[ $command =~ $GH_PR_CREATE_RE ]]; then
      what="PR を作る"
    elif [[ $command =~ $GIT_COMMIT_RE ]]; then
      what="commit する"
      # git -C <path> commit は、そのパスのリポジトリを見る。コマンド全体ではなく commit に当たった部分から
      # 取る（メッセージの中の -C を拾わないため）。空白を含むパスは扱えず、検査せずに通す
      if [[ ${BASH_REMATCH[0]} =~ -C[[:space:]]+([^[:space:]]+) ]]; then
        dir=${BASH_REMATCH[1]}
        dir=${dir#[\"\']}
        dir=${dir%[\"\']}
        dir=${dir/#\~/$HOME}
        [[ $dir == /* ]] || dir="$cwd/$dir"
        cwd=$dir
      fi
    else
      exit 0
    fi
    [ -n "$cwd" ] && git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
    found=$(hits "$cwd")
    [ -n "$found" ] || exit 0
    msg="${what}前に、レビューで繰り返し指摘されている書き方を直してください（誤検知ならユーザーに確認し、SKIP_KB_CHECKS=1 で起動し直してもらう）:
$found"
    jq -n --arg m "$msg" '{
      hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m},
      systemMessage: $m
    }'
    ;;
esac
exit 0
