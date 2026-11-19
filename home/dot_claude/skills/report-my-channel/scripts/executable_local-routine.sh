#!/usr/bin/env bash
# report-my-channel のルーティンを Mac の launchd で動かす。
# クラウドのルーティンで動かせない報告（ローカルのファイルや MCP が要るもの）のためだけに使う。
#
#   local-routine.sh install <slug> <HH:MM[,HH:MM...]> [曜日 0-6 のコンマ区切り]
#   local-routine.sh uninstall <slug>
#   local-routine.sh list
#   local-routine.sh run <slug>
set -Eeuo pipefail

ROUTINE_HOME="${REPORT_MY_CHANNEL_HOME:-$HOME/.claude/report-my-channel}"
AGENTS_DIR="${REPORT_MY_CHANNEL_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${REPORT_MY_CHANNEL_LOG_DIR:-$HOME/Library/Logs}"
LABEL_PREFIX="com.kokikono.report-my-channel"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LAUNCHCTL="${LAUNCHCTL:-launchctl}"
OSASCRIPT="${OSASCRIPT:-osascript}"
CLAUDE="${REPORT_MY_CHANNEL_CLAUDE:-claude}"
DOMAIN="gui/$(id -u)"

DEFAULT_TOOLS="Read,Grep,Glob,Skill,ToolSearch,Bash(gh:*),Bash(git:*)"
DEFAULT_TOOLS+=",mcp__claude_ai_Slack__slack_send_message,mcp__claude_ai_Slack__slack_read_channel"
DEFAULT_TOOLS+=",mcp__claude_ai_Slack__slack_read_thread,mcp__claude_ai_Slack__slack_search_public_and_private"
DEFAULT_TOOLS+=",mcp__claude_ai_Notion__notion-create-pages,mcp__claude_ai_Notion__notion-update-page"
DEFAULT_TOOLS+=",mcp__claude_ai_Notion__notion-fetch,mcp__claude_ai_Notion__notion-search"
DEFAULT_TOOLS+=",mcp__claude_ai_Notion__notion-query-data-sources"

die() { printf '%s\n' "$*" >&2; exit 1; }

routine_file() { printf '%s/routines/%s.md' "$ROUTINE_HOME" "$1"; }
label() { printf '%s.%s' "$LABEL_PREFIX" "$1"; }
plist_path() { printf '%s/%s.plist' "$AGENTS_DIR" "$(label "$1")"; }

check_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug は英小文字・数字・ハイフンだけにしてください: $1"
}

# 定義ファイルのパスを返す。無ければ止める
require_routine() {
  local file
  file="$(routine_file "$1")"
  [[ -f "$file" ]] || die "定義ファイルがありません: $file"
  printf '%s' "$file"
}

# frontmatter の allowed_tools（無ければ空）
extra_tools() {
  awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit}
       NR>1 && sub(/^allowed_tools:[ \t]*/, "") {gsub(/["'\'']/, ""); print; exit}' "$1"
}

# frontmatter を除いた本文
routine_body() {
  awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$1"
}

# 時刻と曜日の組み合わせを全部並べる。曜日が空なら毎日
calendar_xml() {
  local times="$1" days="$2" t d wd
  local -a tlist dlist=("")
  IFS=, read -ra tlist <<<"$times"
  [[ -z "$days" ]] || IFS=, read -ra dlist <<<"$days"
  printf '  <array>\n'
  for t in "${tlist[@]}"; do
    for d in "${dlist[@]}"; do
      wd=""
      [[ -z "$d" ]] || wd="<key>Weekday</key><integer>$d</integer>"
      printf '    <dict>%s<key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' \
        "$wd" "$((10#${t%:*}))" "$((10#${t#*:}))"
    done
  done
  printf '  </array>\n'
}

cmd_install() {
  local slug="${1:-}" times="${2:-}" days="${3:-}" plist log
  local t='([01][0-9]|2[0-3]):[0-5][0-9]'
  check_slug "$slug"
  # plist を書き始める前に検査する（途中で落ちると壊れた plist が残るため）
  [[ "$times" =~ ^$t(,$t)*$ ]] || die "時刻は HH:MM のコンマ区切りで指定してください: $times"
  [[ -z "$days" || "$days" =~ ^[0-6](,[0-6])*$ ]] || die "曜日は 0（日）〜 6（土）のコンマ区切りで指定してください: $days"
  require_routine "$slug" >/dev/null
  plist="$(plist_path "$slug")"
  log="$LOG_DIR/report-my-channel-$slug.log"
  mkdir -p "$AGENTS_DIR" "$LOG_DIR"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(label "$slug")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF</string>
    <string>run</string>
    <string>$slug</string>
  </array>
  <key>StartCalendarInterval</key>
EOF
    calendar_xml "$times" "$days"
    cat <<EOF
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$log</string>
  <key>StandardErrorPath</key>
  <string>$log</string>
</dict>
</plist>
EOF
  } >"$plist"
  # 登録し直すと時刻の変更が反映される。未登録なら bootout は失敗するので無視する
  "$LAUNCHCTL" bootout "$DOMAIN/$(label "$slug")" 2>/dev/null || true
  # bootout は非同期に終わるので、直後の bootstrap は EIO で落ちることがある。少し待って何度か試す
  local i
  for i in 1 2 3 4 5; do
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$plist" && break
    [[ $i -lt 5 ]] || die "launchd への登録に失敗しました: $plist"
    sleep 1
  done
  printf '登録しました: %s（%s %s）\n' "$(label "$slug")" "$times" "${days:-毎日}"
}

cmd_uninstall() {
  local slug="${1:-}" plist
  check_slug "$slug"
  plist="$(plist_path "$slug")"
  # plist が先に消えていても、読み込まれたままのジョブは外せるようにする
  if ! "$LAUNCHCTL" bootout "$DOMAIN/$(label "$slug")" 2>/dev/null && [[ ! -f "$plist" ]]; then
    die "登録されていません: $slug"
  fi
  rm -f "$plist"
  printf '解除しました: %s\n' "$slug"
}

cmd_list() {
  local plist slug
  shopt -s nullglob
  for plist in "$AGENTS_DIR/$LABEL_PREFIX".*.plist; do
    slug="${plist##*/$LABEL_PREFIX.}"
    slug="${slug%.plist}"
    printf '%s\t%s\n' "$slug" "$(routine_file "$slug")"
  done
}

cmd_run() {
  local slug="${1:-}" file tools extra out
  check_slug "$slug"
  file="$(require_routine "$slug")"
  tools="$DEFAULT_TOOLS"
  extra="$(extra_tools "$file")"
  [[ -n "$extra" ]] && tools+=",$extra"
  printf '%s run %s\n' "$(date '+%F %T')" "$slug"
  # 定義ファイルの置き場で走らせる。ルーティンの作業ファイルが業務リポジトリに散らばらないように
  # stderr は混ぜない（警告が混ざると JSON として読めず、成功を失敗と誤る）。launchd がログに書く
  out="$(cd "$ROUTINE_HOME" && "$CLAUDE" -p \
    "/report-my-channel run $(routine_body "$file")" \
    --model sonnet --allowedTools "$tools" --output-format json)" || true
  jq -r '.result // empty' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
  # allowed_tools に足すべきツールを、ログから見つけられるようにする
  jq -r '.permission_denials[]? | "拒否されたツール: \(.tool_name)"' <<<"$out" 2>/dev/null || true
  # claude -p は投稿に失敗しても正常終了するので、スキルが最後に書く REPORT: OK で成否を見る
  if ! jq -e '.is_error == false and (.result | test("REPORT: OK"))' >/dev/null 2>&1 <<<"$out"; then
    "$OSASCRIPT" -e "display notification \"$slug の実行に失敗しました\" with title \"report-my-channel\"" \
      2>/dev/null || true
    return 1
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install) cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    list) cmd_list ;;
    run) cmd_run "$@" ;;
    *) die "使い方: local-routine.sh {install|uninstall|list|run} ..." ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
