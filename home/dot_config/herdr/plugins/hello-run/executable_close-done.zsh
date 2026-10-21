#!/usr/bin/env zsh
# issue がクローズ済みになった hello-run のタブを探して閉じる。pick.zsh の x から呼ばれる。
#
#   close-done.zsh          候補を見せて y/N を訊いてから閉じる
#   close-done.zsh --yes    訊かずに閉じる
#   close-done.zsh --dry-run 候補を出すだけで閉じない
#
# 閉じるのはタブだけで、worktree とブランチは残す。片付けは wrm に任せる
# （未 push のコミットや未コミットの変更を、タブを閉じるついでに消さないため）。
#
# タブの見つけ方と、どの issue のタブかの決め方は issues.zsh と同じ（lib.zsh）。
# CLOSED と確かめられたものだけを閉じる。開いている作業を誤って閉じるほうが、
# 閉じ忘れより痛い。
emulate -L zsh
setopt pipe_fail

typeset mode=ask
case ${1-} in
  "")         mode=ask ;;
  --yes)      mode=yes ;;
  --dry-run)  mode=dry ;;
  *)          print -ru2 -- "usage: close-done.zsh [--yes|--dry-run]"; exit 2 ;;
esac

# popup で結果を読めるよう、対話時だけキー入力を待ってから戻る
__pause() {
  [[ $mode == ask && -t 0 ]] || return 0
  print -rn -- $'\n  何かキーを押すと一覧に戻ります '
  read -k 1
}

if [[ -z ${HELLO_RUN_ROOT:-} || -z ${HELLO_RUN_ISSUE_ORG:-} ]]; then
  typeset rc=${HELLO_RUN_PRIVATE_RC:-$HOME/.pzshrc}
  [[ -r $rc ]] && source "$rc"
  HELLO_RUN_ISSUE_ORG=${HELLO_RUN_ISSUE_ORG:-${HELLO_RUN_ISSUE_REPO%%/*}}
fi
[[ -n ${HELLO_RUN_ROOT:-} ]] || { print -ru2 -- "HELLO_RUN_ROOT が未設定"; __pause; exit 2 }

source "${0:A:h}/lib.zsh"

typeset -A label_of
typeset tab label
while IFS=$'\t' read -r tab label; do
  [[ -n $tab ]] && label_of[$tab]=$label
done < <(__hrp_session_tabs "$HELLO_RUN_ROOT")

if (( ! ${#label_of} )); then
  print -r -- "hello-run のタブはありません"
  __pause; exit 0
fi

# 状態を引いて CLOSED のものだけ候補にする
typeset -a targets
typeset info url state
for tab in ${(ok)label_of}; do
  label=${label_of[$tab]}
  if ! info=$(__hrp_issue_of "$HELLO_RUN_ROOT" "${HELLO_RUN_ISSUE_ORG:-}" "${label#issue-}"); then
    print -r -- "  ?  $label  issue を特定できなかったので残します"
    continue
  fi
  url=${info%%$'\t'*}
  state=${info##*$'\t'}
  [[ $state == CLOSED ]] || continue
  targets+=("$tab")
  print -r -- "  ✔  $label  ${url#https://github.com/} はクローズ済み"
done

if (( ! ${#targets} )); then
  print -r -- "クローズ済み issue のタブはありません"
  __pause; exit 0
fi

case $mode in
  dry) exit 0 ;;
  ask)
    print
    if ! read -q "?${#targets} 個のタブを閉じます（worktree は残します）。よろしいですか? [y/N] "; then
      print; print -r -- "中止しました"
      __pause; exit 0
    fi
    print ;;
esac

integer failed=0
for tab in "${targets[@]}"; do
  if herdr tab close "$tab" >/dev/null 2>&1; then
    print -r -- "  閉じました: ${label_of[$tab]}"
  else
    print -r -- "  閉じられませんでした: ${label_of[$tab]} ($tab)"
    (( failed++ ))
  fi
done
__pause
(( failed == 0 ))
