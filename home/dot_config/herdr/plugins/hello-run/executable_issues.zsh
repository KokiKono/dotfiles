#!/usr/bin/env zsh
# 自分にアサインされた open issue を org 横断で探し、"URL<TAB>表示行" の TSV で吐く。
# タブが残っている issue は、クローズ済みなどで一覧から外れていても末尾に足す。
# pick.zsh から直接と、fzf の reload バインド（再取得）と、プラグインの startup から呼ばれる。
#
#   issues.zsh              キャッシュがあればそれを使う（TTL 内）
#   issues.zsh --refresh    キャッシュを無視して取り直す（fzf の r）
#   issues.zsh --warm       取り直してキャッシュを温めるだけ（出力しない。startup 用）
#
# キャッシュするのは gh の結果だけ。実測で gh が 1.1〜1.5 秒、タブの走査は 0.03 秒で、
# 遅いのは gh しかない。先頭の印は worktree とタブの有無なので、古いと意味が無い。
# よって印は毎回その場で付け直す。
#
# pick.zsh に inline せず別ファイルにしてあるのは、fzf の --bind が **コンマで
# バインドを区切る**ため。jq のフィルタをそのまま reload() に埋めると、中のコンマが
# 区切りとして食われて fzf が起動時に `bind action not specified` で落ちる。
#
# 1 列目を URL にしてあるのは、issue 番号がリポジトリ間で一意でないため。
# hello-run には URL を渡す（hello-run 側が URL を解釈する）。
# 2 列目は桁を揃えた表示用の 1 列。fzf は列を揃えないので、ここで組み立てる。
#
# 先頭の印は、その issue の作業環境がどこまで出来ているかを表す。hello-run が
# 見るのと同じもの（セッションディレクトリと、issue-<N> ラベルのタブ）を見る。
#   ●  タブまである    → enter で切り替えるだけ
#   ○  worktree だけ   → enter でタブを作る
#   ・ なにも無い      → enter で worktree から作る
emulate -L zsh
setopt pipe_fail

typeset mode=use
case ${1-} in
  "")         mode=use ;;
  --refresh)  mode=refresh ;;
  --warm)     mode=warm ;;
  *)          print -ru2 -- "usage: issues.zsh [--refresh|--warm]"; exit 2 ;;
esac

# startup から直に呼ばれたときは pick.zsh の export が無いので、自分で読む。
if [[ -z ${HELLO_RUN_ISSUE_ORG:-} ]]; then
  local rc=${HELLO_RUN_PRIVATE_RC:-$HOME/.pzshrc}
  [[ -r $rc ]] && source "$rc"
  HELLO_RUN_ISSUE_ORG=${HELLO_RUN_ISSUE_ORG:-${HELLO_RUN_ISSUE_REPO%%/*}}
fi
[[ -n ${HELLO_RUN_ISSUE_ORG:-} ]] || { print -ru2 -- "HELLO_RUN_ISSUE_ORG が未設定"; exit 2 }

# 置き場は herdr がプラグインに与える state ディレクトリ。herdr の外では ~/.cache へ。
typeset cache_dir=${HELLO_RUN_CACHE_DIR:-${HERDR_PLUGIN_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hello-run}}
typeset cache=$cache_dir/issues-${HELLO_RUN_ISSUE_ORG//[^A-Za-z0-9._-]/_}.tsv
integer ttl=${HELLO_RUN_CACHE_TTL:-600}

# gh の生結果（URL/リポジトリ/番号/タイトル）を取り直してキャッシュに書く。
# 書き込みは一時ファイル経由。途中で死んだ中身を次回読まないため。
__fetch() {
  local tmp
  mkdir -p "$cache_dir" || return 1
  tmp=$(mktemp "$cache_dir/.issues.XXXXXX") || return 1
  if gh search issues \
       --owner "$HELLO_RUN_ISSUE_ORG" \
       --assignee @me \
       --state open \
       --sort updated \
       --limit "${HELLO_RUN_CACHE_LIMIT:-${HELLO_RUN_LIMIT:-100}}" \
       --json url,repository,number,title \
     | jq -r '.[] | [.url, .repository.name, (.number|tostring), .title] | @tsv' >"$tmp"
  then
    mv -f "$tmp" "$cache"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# TTL 内のキャッシュがあるか（zsh の glob 修飾子 mm で「更新から n 分以内」）
__cache_fresh() {
  [[ -s $cache ]] || return 1
  local -a fresh=( $cache(Nms-$ttl) )
  (( ${#fresh} ))
}

if [[ $mode == use ]] && __cache_fresh; then
  : # そのまま使う
else
  if ! __fetch; then
    # 取れなくても手元にキャッシュがあればそれを見せる。一覧が消えるよりまし。
    [[ -s $cache ]] || { print -ru2 -- "gh search issues に失敗しました"; exit 1 }
    print -ru2 -- "gh search issues に失敗したのでキャッシュを表示します"
  fi
fi
[[ $mode == warm ]] && exit 0

typeset -a rows
rows=(${(f)"$(<$cache)"})

# 既にタブがあるもの。herdr の外なら空のまま（印は worktree 止まり）。
# 見つけ方は hello-run が切り替え先を決めるときと同じ（lib.zsh）。ラベルだけ同じ別物に
# ● が付くと、enter でそこへ飛ばされる。
source "${0:A:h}/lib.zsh"
typeset -A has_tab
if command -v herdr >/dev/null 2>&1; then
  local tab label
  while IFS=$'\t' read -r tab label; do
    [[ -n $label ]] && has_tab[$label]=1
  done < <(__hrp_session_tabs "${HELLO_RUN_ROOT:-}")
fi

# タブが残っているのに一覧に無い issue（クローズ済みや、自分のアサインが外れたもの）も出す。
# gh の一覧は open かつ自分にアサインのものだけなので、そのままだとタブに戻る道が無くなる。
# 1 件ごとに gh を叩くので結果をキャッシュする。対象は一覧に無いタブの分だけで、
# r（--refresh）で取り直す。書き戻すのは今あるタブの分だけなので、閉じたタブの分は消える。
typeset extra_cache=$cache_dir/tab-issues-${HELLO_RUN_ISSUE_ORG//[^A-Za-z0-9._-]/_}.tsv
typeset -A listed cached_extra
local line num info url repo state title
for line in "${rows[@]}"; do listed[${${(s:	:)line}[3]}]=1; done
if [[ $mode == use && -s $extra_cache ]]; then
  for line in ${(f)"$(<$extra_cache)"}; do cached_extra[${line%%	*}]=${line#*	}; done
fi
typeset -a extra_lines
for label in ${(ok)has_tab}; do
  num=${label#issue-}
  (( ${+listed[$num]} )) && continue
  if (( ${+cached_extra[$num]} )); then
    info=${cached_extra[$num]}
  else
    info=$(__hrp_issue_of "${HELLO_RUN_ROOT:-}" "$HELLO_RUN_ISSUE_ORG" "$num") || continue
  fi
  extra_lines+=("$num	$info")
  # url repo num title。state は表示の飾りに使う
  url=${${(s:	:)info}[1]} repo=${${(s:	:)info}[2]} state=${info##*	}
  title=${${info#*	*	}%	*}
  [[ $state == CLOSED ]] && title="[closed] $title"
  rows+=("$url	$repo	$num	$title")
done
if (( ${#extra_lines} )); then
  print -rl -- "${extra_lines[@]}" >"$extra_cache" 2>/dev/null
else
  rm -f "$extra_cache"
fi
(( ${#rows} )) || exit 0

# リポジトリ名と番号の桁を揃える
integer rw=0 nw=0
for line in "${rows[@]}"; do
  [[ -z $line ]] && continue
  repo=${${(s:	:)line}[2]}
  num=${${(s:	:)line}[3]}
  (( ${#repo} > rw )) && rw=${#repo}
  (( ${#num}  > nw )) && nw=${#num}
done

for line in "${rows[@]}"; do
  [[ -z $line ]] && continue
  url=${${(s:	:)line}[1]}
  repo=${${(s:	:)line}[2]}
  num=${${(s:	:)line}[3]}
  title=${line#*	*	*	}

  local mark='・'
  if (( ${+has_tab[issue-$num]} )); then
    mark='●'
  elif [[ -n ${HELLO_RUN_ROOT:-} && -d "$HELLO_RUN_ROOT/.sessions/issue-$num" ]]; then
    mark='○'
  fi

  printf '%s\t%s %-*s %*s  %s\n' "$url" "$mark" "$rw" "$repo" "$nw" "$num" "$title"
done
