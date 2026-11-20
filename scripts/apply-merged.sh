#!/usr/bin/env bash
# マージ済みの PR が home/ で変えたファイルだけを、最新の master から $HOME に apply する。
#
# 使い方: scripts/apply-merged.sh [--dry-run] <PR番号 | --commit <マージコミット>>
#
# 素の `chezmoi apply` を使わない理由は 2 つ。
#   - chezmoi のソース（このリポジトリのチェックアウト）は作業中のブランチにいることがあり、
#     そこから apply するとマージしていない変更まで配ってしまう。そのため origin/master を一時的な worktree に出して使う
#   - settings.json のようにアプリが自分で書き換えるファイルは、ライブ側に追跡外の変更が溜まっている。
#     丸ごと apply するとそれが消えるので、ライブが PR の前の内容のままのファイルだけを apply する
#
# 出力は 1 ファイル 1 行の `<状態>\t<配備先>`。状態は次のどれか。
#   applied     PR の前の内容のままだったので apply した（--dry-run では apply する予定のもの）
#   up-to-date  すでに PR の後の内容になっている
#   conflict    ライブが PR の前とも後とも違う。apply していない（PR の変更分だけを手で足す）
#   removed     PR で消したファイル。chezmoi は消さないので、要らなければ手で消す
# conflict か removed があれば終了コード 3。差分は CONFLICT_DIR（既定は一時ディレクトリ）に
# <配備先のパスの / を % にした名前>.{old,new} で残す。
# apply に失敗したら終了コード 1。applied の行は apply の前に出すので、配られていないものを含む。
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# テストで配備先と設定を差し替えるため（例: "--destination /tmp/h --config /tmp/h/c.yaml"）
read -r -a CHEZMOI_FLAGS <<<"${APPLY_MERGED_CHEZMOI_FLAGS:-}"

die() { echo "apply-merged: $*" >&2; exit 1; }

chezmoi_at() {
  local source="$1"; shift
  chezmoi --source "$source" ${CHEZMOI_FLAGS[@]+"${CHEZMOI_FLAGS[@]}"} "$@"
}

merge_commit_of() {
  local pr="$1" state sha
  # --repo に remote の URL を渡すと SSH 形式で解決できないので、リポジトリの中で gh に解決させる
  read -r state sha < <(cd "$REPO_ROOT" && gh pr view "$pr" \
    --json state,mergeCommit --jq '"\(.state) \(.mergeCommit.oid // "")"')
  [ "$state" = "MERGED" ] || die "PR $pr はマージされていない（$state）"
  echo "$sha"
}

# home/ の下で、chezmoi が配るファイルだけ（.chezmoi* はスクリプトや設定なので外す）。
# 第 1 親との差分を PR の変更とみなせるのは、このリポジトリが squash merge しか許していないから
# （rebase merge だと最後のコミットの分しか拾えない）
changed_sources() {
  git -C "$REPO_ROOT" diff --no-renames --name-status "$1^1" "$1" -- home/ \
    | awk -F'\t' '$2 !~ /^home\/\.chezmoi/ { print $1 "\t" $2 }'
}

main() {
  local dry=0 commit="" pr=""
  while (($#)); do
    case "$1" in
      --dry-run) dry=1 ;;
      --commit) commit="$2"; shift ;;
      -h|--help) sed -n '2,19p' "$0"; return 0 ;;
      *) pr="$1" ;;
    esac
    shift
  done
  [ -n "$commit" ] || [ -n "$pr" ] || die "PR 番号か --commit を渡す"

  git -C "$REPO_ROOT" fetch -q origin
  [ -n "$commit" ] || commit="$(merge_commit_of "$pr")"
  git -C "$REPO_ROOT" merge-base --is-ancestor "$commit" origin/master \
    || die "$commit は origin/master に入っていない"

  # EXIT の trap は main を抜けた後に走るので、後始末に使う 3 つは local にしない
  work="$(mktemp -d)"
  new="$work/new"
  old="$work/old"
  CONFLICT_DIR="${CONFLICT_DIR:-$work/conflicts}"
  mkdir -p "$CONFLICT_DIR"
  KEEP_WORK=0
  # trap の中でも errexit が効くので、1 つずつ失敗を握りつぶす。worktree を外してから消す
  cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$new" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree remove --force "$old" 2>/dev/null || true
    [ "$KEEP_WORK" = 1 ] || rm -rf "$work"
  }
  trap cleanup EXIT
  git -C "$REPO_ROOT" worktree add -q --detach "$new" origin/master
  git -C "$REPO_ROOT" worktree add -q --detach "$old" "$commit^1"

  local status src target key to_apply=() rc=0
  while IFS=$'\t' read -r status src; do
    if [ "$status" = "D" ]; then
      target="$(chezmoi_at "$old" target-path "$old/$src")"
      printf 'removed\t%s\n' "$target"
      rc=3
      continue
    fi
    # .chezmoiignore で配らないファイルは target-path は出るが cat が失敗する
    target="$(chezmoi_at "$new" target-path "$new/$src")"
    key="$CONFLICT_DIR/$(printf '%s' "$target" | tr / %)"
    chezmoi_at "$new" cat "$target" >"$key.new" 2>/dev/null || { rm -f "$key.new"; continue; }
    chezmoi_at "$old" cat "$target" >"$key.old" 2>/dev/null || rm -f "$key.old"

    if [ -f "$target" ] && cmp -s "$target" "$key.new"; then
      printf 'up-to-date\t%s\n' "$target"
    elif { [ -f "$key.old" ] && [ -f "$target" ] && cmp -s "$target" "$key.old"; } \
      || { [ ! -f "$key.old" ] && [ ! -e "$target" ]; }; then
      printf 'applied\t%s\n' "$target"
      to_apply+=("$target")
    else
      printf 'conflict\t%s\n' "$target"
      rc=3
      continue
    fi
    rm -f "$key.new" "$key.old"
  done < <(changed_sources "$commit")

  local dir failed=0 missing=()
  if ((${#to_apply[@]})) && ((!dry)); then
    # chezmoi は親ディレクトリが無いファイルを apply できない（PR がディレクトリごと足したとき）。
    # ディレクトリを再帰で apply すると PR が変えていないファイルまで配り、--parent-dirs は既にある親の
    # 権限や symlink まで書き換える。無い親だけを再帰なしで対象に足す（親を先に処理するのは chezmoi がやる）
    for target in "${to_apply[@]}"; do
      dir="$(dirname "$target")"
      while [ ! -e "$dir" ] && [ ! -L "$dir" ]; do
        missing+=("$dir")
        dir="$(dirname "$dir")"
      done
    done
    chezmoi_at "$new" apply --exclude scripts --force --recursive=false \
      ${missing[@]+"${missing[@]}"} "${to_apply[@]}" || failed=1
  fi
  git -C "$REPO_ROOT" diff --quiet "$commit^1" "$commit" -- install/ home/.chezmoiscripts/ \
    || echo "install スクリプトが変わっているが、実行していない（必要なら bash install/macos/<名前>.sh）" >&2
  # 衝突の材料は呼び出し側が読むので残す。CONFLICT_DIR を渡されたときは、そのディレクトリには触らない
  if [ "$rc" -eq 3 ]; then
    KEEP_WORK=1
    echo "conflict の PR 前後の内容: $CONFLICT_DIR/<配備先>.{old,new}" >&2
  fi
  # applied の行は apply の前に出しているので、失敗したら配っていないことをはっきり伝える
  ((!failed)) || die "apply に失敗した。上の applied の行は配られていないものを含む（直してから流し直す）"
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
