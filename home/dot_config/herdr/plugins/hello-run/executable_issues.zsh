#!/usr/bin/env zsh
# 自分にアサインされた open issue を org 横断で探し、"URL<TAB>表示行" の TSV で吐く。
# pick.zsh から直接と、fzf の reload バインド（再取得）から呼ばれる。
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
#
# 対象 org とセッションの置き場は環境変数で受け取る（pick.zsh が export する）。
emulate -L zsh
setopt pipe_fail

[[ -n ${HELLO_RUN_ISSUE_ORG:-} ]] || { print -ru2 -- "HELLO_RUN_ISSUE_ORG が未設定"; exit 2 }

# 既にタブがあるものの一覧。herdr の外なら空のまま（印は worktree 止まり）。
# hello-run が探すのに合わせて全 workspace を見る。タブはそれを作ったときに居た
# workspace に残るので、現在の workspace だけ見ると印と実際の挙動がずれる。
typeset -A has_tab
if command -v herdr >/dev/null 2>&1; then
  local ws label
  for ws in ${(f)"$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.workspace_id // empty')"}; do
    [[ -n $ws ]] || continue
    while IFS= read -r label; do
      [[ -n $label ]] && has_tab[$label]=1
    done < <(herdr tab list --workspace "$ws" 2>/dev/null \
              | jq -r '.result.tabs[]?.label // empty' 2>/dev/null)
  done
fi

# gh issue list はリポジトリ単位なので、org 横断には gh search issues を使う。
typeset -a rows
rows=("${(@f)$(gh search issues \
  --owner "$HELLO_RUN_ISSUE_ORG" \
  --assignee @me \
  --state open \
  --sort updated \
  --limit "${HELLO_RUN_LIMIT:-100}" \
  --json url,repository,number,title \
  | jq -r '.[] | [.url, .repository.name, (.number|tostring), .title] | @tsv')}")
(( ${#rows} )) || exit 0

# リポジトリ名と番号の桁を揃える
integer rw=0 nw=0
local url repo num title
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
