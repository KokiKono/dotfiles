# herdr を叩く zsh モジュール（hello-run / dev-server）の共通部分。
# 依存: herdr, jq。
#
# ここに置くのは「herdr の扱いで一度踏んだ地雷」だけ。コピーして2本持つと、
# 片方だけ直したときに印と挙動がずれて、どちらが嘘か分からなくなる。
#
#   1. タブの探索を現在の workspace に固定しない（タブは作ったときの workspace に残る）
#   2. ラベルの一致だけでタブを同一視しない（issue 番号はリポジトリ間で一意でない）
#   3. プラグインの pane には HERDR_WORKSPACE_ID が渡ってこない

# __hz_workspace_id → 今いる workspace の id。特定できなければ 1 を返す。
# herdr はプラグインの pane に HERDR_WORKSPACE_ID を渡さない（代わりに
# HERDR_PLUGIN_CONTEXT_JSON に入れてくる）ので、popup から呼ばれた呼び出し元が
# 空の id を tab create に渡すと workspace_not_found で落ちる。
__hz_workspace_id() {
  emulate -L zsh
  local ws=${HERDR_WORKSPACE_ID:-}
  if [[ -z $ws && -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]]; then
    ws=$(print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.workspace_id // empty' 2>/dev/null)
  fi
  if [[ -z $ws ]]; then
    ws=$(herdr workspace list 2>/dev/null \
           | jq -r '[.result.workspaces[]? | select(.focused) | .workspace_id] | first // empty')
  fi
  [[ -n $ws ]] || return 1
  print -r -- "$ws"
}

# __hz_tab_has_cwd_under <tab_id> <dir> : そのタブのペインが dir の下に居るか。
# dir が空なら検証しない（真を返す）。
__hz_tab_has_cwd_under() {
  emulate -L zsh
  local tab=$1 dir=$2
  [[ -n $dir ]] || return 0
  herdr pane list 2>/dev/null | jq -e --arg t "$tab" --arg d "$dir" \
    '[.result.panes[]? | select(.tab_id == $t) | (.cwd // "")]
       | any(. == $d or startswith($d + "/"))' >/dev/null 2>&1
}

# __hz_find_tab <label> [<dir>] → "<workspace_id><TAB><tab_id>"。無ければ 1 を返す。
# 現在の workspace だけでなく全部を見る。タブはそれを作ったときに居た workspace に
# 残るので、別の workspace から呼ぶと現在の workspace には無い。そこで見つけ損なうと、
# 既にあるのに同じラベルのタブをもう 1 つ作ってしまう。
# dir を渡すと、ラベルが一致したうえでペインが dir 配下に居ることまで確かめる。
__hz_find_tab() {
  emulate -L zsh
  local label=$1 dir=${2:-} ws tab
  for ws in ${(f)"$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id // empty')"}; do
    [[ -n $ws ]] || continue
    for tab in ${(f)"$(herdr tab list --workspace "$ws" 2>/dev/null \
            | jq -r --arg l "$label" '.result.tabs[]? | select(.label==$l) | .tab_id')"}; do
      [[ -n $tab ]] || continue
      __hz_tab_has_cwd_under "$tab" "$dir" || continue
      print -r -- "$ws"$'\t'"$tab"
      return 0
    done
  done
  return 1
}
