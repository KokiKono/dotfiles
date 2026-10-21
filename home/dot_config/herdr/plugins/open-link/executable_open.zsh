#!/usr/bin/env zsh
# kokikono.open-link の本体。Ctrl+クリックされた URL を terminal-browser で開く。
# URL は herdr が HERDR_PLUGIN_CLICKED_URL で渡してくる（手で試すときは引数でもよい）。

url=${1:-${HERDR_PLUGIN_CLICKED_URL:-}}
[[ -n $url ]] || { print -ru2 -- "open-link: URL がありません"; exit 1; }

# terminal-browser が無い環境でクリックを無かったことにしない
if ! command -v terminal-browser >/dev/null 2>&1; then
  exec open "$url"
fi

# terminal-browser は HERDR_PANE_ID / HERDR_TAB_ID で「どのタブのブラウザか」「どこを
# split するか」を決める。action はペインの外で走るのでこれが付いてくる保証が無く、
# クリックされたペインは context JSON の側にしか無い。
if [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] && command -v jq >/dev/null 2>&1; then
  pane_id=$(print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.focused_pane_id // empty' 2>/dev/null)
  tab_id=$(print -r -- "$HERDR_PLUGIN_CONTEXT_JSON" | jq -r '.tab_id // empty' 2>/dev/null)
  [[ -n $pane_id ]] && export HERDR_PANE_ID=$pane_id
  [[ -n $tab_id ]] && export HERDR_TAB_ID=$tab_id
fi

# new-tab はタブ内のブラウザが 1 つならそこにタブを足し、無ければ右に split して開く。
# クリックのたびにペインが増えないよう open ではなくこちらを使う。
# ブラウザが 2 つ以上あると new-tab はどれに足すか決められずに失敗するので、そのときは
# 新しく split して開く。
terminal-browser new-tab "$url" || terminal-browser open "$url" --split right
