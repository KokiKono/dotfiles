#!/usr/bin/env bats

load ../test_helper

# マージ後に、PR が home/ で変えたファイルだけを apply するスクリプトを検証する。
# 使い捨てのリポジトリ（origin は bare）と HOME を作り、PR の前の状態を apply してから流す。

setup() {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    R="${BATS_TEST_TMPDIR}/repo"
    H="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$R/scripts" "$R/home" "$H"
    cp "${REPO_ROOT}/scripts/apply-merged.sh" "$R/scripts/"
    echo home >"$R/.chezmoiroot"
    echo a0 >"$R/home/dot_a"
    echo b0 >"$R/home/dot_b"
    echo c0 >"$R/home/dot_c"
    printf '.ignored\n' >"$R/home/.chezmoiignore"
    git init -q -b master "$R"
    git init -q --bare "${BATS_TEST_TMPDIR}/origin.git"
    git -C "$R" remote add origin "${BATS_TEST_TMPDIR}/origin.git"
    commit "base"
    export APPLY_MERGED_CHEZMOI_FLAGS="--destination $H --config $H/chezmoi.yaml --persistent-state $H/state.boltdb --cache $H/cache"
    : >"$H/chezmoi.yaml"
    # shellcheck disable=SC2086
    chezmoi --source "$R" $APPLY_MERGED_CHEZMOI_FLAGS apply --force
    export CONFLICT_DIR="${BATS_TEST_TMPDIR}/conflicts"
}

commit() {
    git -C "$R" add -A
    git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m "$1"
    git -C "$R" push -q origin master
}

# PR: a を変え、b を変え、new を足し、c を消し、配らない ignored と home の外も変える
merge_pr() {
    echo a1 >"$R/home/dot_a"
    echo b1 >"$R/home/dot_b"
    echo n1 >"$R/home/dot_new"
    rm "$R/home/dot_c"
    echo x >"$R/home/dot_ignored"
    echo doc >"$R/README.md"
    commit "pr"
    PR_SHA="$(git -C "$R" rev-parse HEAD)"
}

@test "apply-merged: applies files untouched since before the PR, and keeps locally changed ones" {
    merge_pr
    echo "b0 + app" >"$H/.b"   # アプリがライブを書き換えた
    run "$R/scripts/apply-merged.sh" --commit "$PR_SHA"
    [ "$status" -eq 3 ]
    [[ "$output" == *"applied	$H/.a"* ]] || false
    [[ "$output" == *"conflict	$H/.b"* ]] || false
    [[ "$output" == *"applied	$H/.new"* ]] || false
    [[ "$output" == *"removed	$H/.c"* ]] || false
    [[ "$output" != *"ignored"* ]] || false
    [ "$(cat "$H/.a")" = a1 ]
    [ "$(cat "$H/.new")" = n1 ]
    [ "$(cat "$H/.b")" = "b0 + app" ]
    # 衝突は PR の前後の内容を残し、呼び出し側が変更分だけを足せるようにする
    [ "$(cat "$CONFLICT_DIR/$(printf '%s' "$H/.b" | tr / %).old")" = b0 ]
    [ "$(cat "$CONFLICT_DIR/$(printf '%s' "$H/.b" | tr / %).new")" = b1 ]
}

@test "apply-merged: a second run reports everything as up to date" {
    rm "$R/home/dot_c"
    echo a1 >"$R/home/dot_a"
    commit "pr"
    sha="$(git -C "$R" rev-parse HEAD)"
    run "$R/scripts/apply-merged.sh" --commit "$sha"
    [ "$status" -eq 3 ]   # removed が残る
    run "$R/scripts/apply-merged.sh" --commit "$sha"
    [[ "$output" == *"up-to-date	$H/.a"* ]] || false
}

@test "apply-merged: applies from the latest master, not from the merge commit" {
    echo a1 >"$R/home/dot_a"
    commit "pr"
    sha="$(git -C "$R" rev-parse HEAD)"
    echo a2 >"$R/home/dot_a"
    commit "later"
    run "$R/scripts/apply-merged.sh" --commit "$sha"
    [ "$status" -eq 0 ]
    [ "$(cat "$H/.a")" = a2 ]
}

@test "apply-merged: --dry-run reports without touching HOME" {
    echo a1 >"$R/home/dot_a"
    commit "pr"
    run "$R/scripts/apply-merged.sh" --dry-run --commit "$(git -C "$R" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"applied	$H/.a"* ]] || false
    [ "$(cat "$H/.a")" = a0 ]
}

@test "apply-merged: applies files whose directories do not exist yet, without their siblings" {
    # 別の PR が同じディレクトリに足したファイル（まだ配っていない）は、この PR の対象ではない
    mkdir -p "$R/home/dot_dir/sub"
    echo n1 >"$R/home/dot_dir/sub/new"
    commit "pr"
    sha="$(git -C "$R" rev-parse HEAD)"
    echo o1 >"$R/home/dot_dir/other"
    commit "later"
    run "$R/scripts/apply-merged.sh" --commit "$sha"
    [ "$status" -eq 0 ]
    [[ "$output" == *"applied	$H/.dir/sub/new"* ]] || false
    [ "$(cat "$H/.dir/sub/new")" = n1 ]
    [ ! -e "$H/.dir/other" ]
}

@test "apply-merged: leaves existing parent directories as they are" {
    # 親が symlink でも権限が違っても、PR が変えたのは中のファイルだけ
    mkdir -p "$R/home/private_dot_pv" "$R/home/dot_ln" "${BATS_TEST_TMPDIR}/real"
    mkdir -m 755 "$H/.pv"
    ln -s "${BATS_TEST_TMPDIR}/real" "$H/.ln"
    echo keep >"${BATS_TEST_TMPDIR}/real/mine"
    echo p1 >"$R/home/private_dot_pv/f"
    echo l1 >"$R/home/dot_ln/f"
    commit "pr"
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [ "$(cat "$H/.pv/f")" = p1 ]
    [ "$(stat -f %Lp "$H/.pv")" = 755 ]
    [ -L "$H/.ln" ]
    [ "$(cat "$H/.ln/f")" = l1 ]
    [ "$(cat "$H/.ln/mine")" = keep ]
}

@test "apply-merged: a failed apply still keeps the conflict material" {
    echo a1 >"$R/home/dot_a"
    echo b1 >"$R/home/dot_b"
    commit "pr"
    echo "b0 + app" >"$H/.b"
    chmod a-w "$H"
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    chmod u+w "$H"
    [ "$status" -eq 1 ]
    [ "$(cat "$CONFLICT_DIR/$(printf '%s' "$H/.b" | tr / %).new")" = b1 ]
}

@test "apply-merged: says nothing was applied when chezmoi fails" {
    echo a1 >"$R/home/dot_a"
    commit "pr"
    chmod a-w "$H"
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    chmod u+w "$H"
    [ "$status" -eq 1 ]
    [[ "$output" == *"apply に失敗した"* ]] || false
}

@test "apply-merged: ignores the checkout's own branch and refuses unmerged commits" {
    git -C "$R" switch -q -c wip
    echo wip >"$R/home/dot_a"
    git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qam wip
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"origin/master に入っていない"* ]] || false
    [ "$(cat "$H/.a")" = a0 ]
}

@test "apply-merged: leaves no worktrees behind" {
    echo a1 >"$R/home/dot_a"
    commit "pr"
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    [ "$(git -C "$R" worktree list | wc -l | tr -d ' ')" = 1 ]
}

@test "apply-merged: resolves a PR number with gh run inside the repo, whatever the remote's format" {
    echo a1 >"$R/home/dot_a"
    commit "pr"
    sha="$(git -C "$R" rev-parse HEAD)"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    # SSH 形式の remote を --repo に渡すと gh は解決できないので、リポジトリの中で --repo なしで呼ばれることを確かめる
    cat >"${BATS_TEST_TMPDIR}/bin/gh" <<STUB
#!/bin/bash
[[ " \$* " == *" --repo "* ]] && { echo "gh: --repo used" >&2; exit 1; }
[ "\$(pwd -P)" = "$(cd "$R" && pwd -P)" ] || { echo "gh: not in repo" >&2; exit 1; }
echo "MERGED $sha"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
    PATH="${BATS_TEST_TMPDIR}/bin:$PATH" run "$R/scripts/apply-merged.sh" 1
    [ "$status" -eq 0 ]
    [ "$(cat "$H/.a")" = a1 ]
}

@test "apply-merged: keeps a caller-supplied CONFLICT_DIR and its contents" {
    mkdir -p "$CONFLICT_DIR"
    echo keep >"$CONFLICT_DIR/mine"
    echo a1 >"$R/home/dot_a"
    commit "pr"
    run "$R/scripts/apply-merged.sh" --commit "$(git -C "$R" rev-parse HEAD)"
    [ "$status" -eq 0 ]
    [ "$(cat "$CONFLICT_DIR/mine")" = keep ]
}
