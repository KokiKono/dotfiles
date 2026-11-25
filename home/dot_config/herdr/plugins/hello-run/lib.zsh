# issues.zsh と close-done.zsh の共通部分。source して使う。依存: herdr か herdr-app, jq, gh。
#
# 「どのタブが hello-run のものか」と「そのタブはどの issue のものか」を 2 本で
# 別々に持つと、一覧の印と x で閉じる対象がずれる。だからここに 1 つだけ置く。

# タブの一覧の取り方は TUI と app で違い、その差は zsh モジュールの herdr-lib.zsh が持つ。
# プラグインから見た zsh/ の位置は、ソース（home/dot_config/）でも配備先（~/.config/）でも
# ../../../zsh で同じなので相対で引く。HERDR_LIB はテストが差し替えるためのもの。
source "${HERDR_LIB:-${0:A:h}/../../../zsh/herdr-lib.zsh}"

# __hrp_session_tabs <root> → "<tab_id>\t<label>" を 1 行ずつ。
# issue-<N> ラベルのタブを全 workspace から集める（タブは作ったときの workspace に残る）。
# root があれば、ペインがそのセッションディレクトリ配下に居るものだけに絞る。
# ラベルだけで決めると、同じラベルの別物に印を付けたり閉じたりしてしまう。
# root が無いと検証しようがないので、ラベルだけで判断する。
__hrp_session_tabs() {
  emulate -L zsh
  local root=$1 ws tab label cwd
  local -A label_of
  while IFS=$'\t' read -r ws tab label; do
    [[ -n $tab && $label == issue-<-> ]] && label_of[$tab]=$label
  done < <(__hz_tabs)
  (( ${#label_of} )) || return 0
  if [[ -z $root ]]; then
    for tab in ${(ok)label_of}; do print -r -- "$tab"$'\t'"${label_of[$tab]}"; done
    return 0
  fi
  # ペインの一覧は 1 回だけ取る。タブ数に関係なく herdr（app では herdr-app と hc）への往復は増やさない
  local -A seen
  while IFS=$'\t' read -r tab cwd; do
    label=${label_of[$tab]:-}
    [[ -n $label && -n $cwd && -z ${seen[$tab]:-} ]] || continue
    if [[ $cwd == "$root/.sessions/$label" || $cwd == "$root/.sessions/$label/"* ]]; then
      seen[$tab]=1
      print -r -- "$tab"$'\t'"$label"
    fi
  done < <(__hz_tab_cwds)
}

# __hrp_issue_of <root> <org> <num> → "<url>\t<repo>\t<title>\t<state>"（state は OPEN / CLOSED）。
# 特定できなければ 1 を返す。
# issue 番号はリポジトリ間で一意でないので、hello-run がセッションディレクトリに残す
# .issue-url でリポジトリを決める。それが無い古いセッションは、自分にアサインされた
# issue を org 横断で番号検索し、ちょうど 1 件当たったときだけそれとみなす。
# HELLO_RUN_ISSUE_REPO で代用しないのは、ピッカーが org 横断で issue を出すので、
# そこから作ったセッションの issue は別のリポジトリにあることが多いため。
__hrp_issue_of() {
  emulate -L zsh
  local root=$1 org=$2 num=$3 url="" repo
  local f=$root/.sessions/issue-$num/.issue-url
  [[ -n $root && -r $f ]] && url=$(<"$f")
  if [[ -n $url ]]; then
    repo=$(print -r -- "$url" | sed -n -E 's#^https://github\.com/([^/]+/[^/]+)/issues/[0-9]+.*$#\1#p')
    [[ -n $repo ]] || return 1
    gh issue view "$num" --repo "$repo" --json url,title,state 2>/dev/null \
      | jq -er --arg r "${repo#*/}" '[.url, $r, .title, .state] | @tsv' 2>/dev/null
    return
  fi
  [[ -n $org ]] || return 1
  # 検索語の番号は本文にも当たるので、番号の一致は jq で確かめ直す
  local -a hits
  hits=(${(f)"$(gh search issues --owner "$org" --assignee @me \
                 --json url,number,title,state,repository -- "$num" 2>/dev/null \
               | jq -r --argjson n "$num" \
                   '.[] | select(.number == $n) | [.url, .repository.name, .title, (.state | ascii_upcase)] | @tsv' \
                   2>/dev/null)"})
  (( ${#hits} == 1 )) || return 1
  print -r -- "${hits[1]}"
}
