#!/usr/bin/env bats

load ../test_helper

# comment-check スキルの added_comments.py（差分で足したコメントの抜き出し）を検証する。

setup() {
    SCRIPT="${REPO_ROOT}/home/dot_claude/skills/comment-check/scripts/executable_added_comments.py"
    R="${BATS_TEST_TMPDIR}/repo"
    git init -q -b main "$R"
    git -C "$R" config user.name t
    git -C "$R" config user.email t@example.com
    git -C "$R" config commit.gpgsign false
    printf '%s\n' '# old comment' 'a = 1' >"$R/a.rb"
    git -C "$R" add -A
    git -C "$R" commit -q -m init
    git -C "$R" update-ref refs/remotes/origin/main HEAD
}

blocks() { python3 "$SCRIPT" "$R" | jq -c "$1"; }

@test "comment-check: lists only the comments added since the default branch" {
    printf '%s\n' '# new one' '# new two' 'b = 2' >>"$R/a.rb"
    run blocks '.blocks'
    [ "$status" -eq 0 ]
    # 連続する行は 1 つのかたまりにし、前からあるコメントは出さない
    [ "$output" = '[{"file":"a.rb","start":3,"end":4,"text":"# new one\n# new two"}]' ]
}

@test "comment-check: sees committed, uncommitted and untracked changes" {
    echo '# committed' >>"$R/a.rb"
    git -C "$R" commit -q -am c
    echo '# uncommitted' >>"$R/a.rb"
    echo '// untracked' >"$R/b.ts"
    run blocks '[.blocks[].text]'
    [ "$output" = '["# committed\n# uncommitted","// untracked"]' ]
}

@test "comment-check: picks trailing and block comments, but not strings or URLs" {
    cat >"$R/b.tsx" <<'TSX'
const url = "https://example.com/#top"
const a = 1 // trailing
/**
 * block
 */
export const X = () => <div>{/* jsx */}</div>
TSX
    echo 'c = "a#b" # trailing' >>"$R/a.rb"
    # 行頭の * でも、参照外しはコメントではない
    printf '%s\n' 'func f(p *int) {' '*p = 1' '}' >"$R/c.go"
    run blocks '[.blocks[] | "\(.file):\(.start)-\(.end)"]'
    [ "$output" = '["a.rb:3-3","b.tsx:2-2","b.tsx:4-4","b.tsx:6-6"]' ]
}

@test "comment-check: skips tool directives, shebangs and files that are not code" {
    printf '%s\n' '#!/bin/bash' '# shellcheck disable=SC2086' 'x=1' >"$R/s.sh"
    printf '%s\n' '# frozen_string_literal: true' 'x = 1 # rubocop:disable Style/X' >"$R/d.rb"
    printf '%s\n' '// eslint-disable-next-line no-console' '// @ts-expect-error' >"$R/d.ts"
    echo '# heading' >"$R/doc.md"
    run blocks '.count'
    [ "$output" = "0" ]
}

@test "comment-check: --base narrows the range" {
    echo '# first' >>"$R/a.rb"
    git -C "$R" commit -q -am first
    echo 'z = 1' >>"$R/a.rb"
    echo '# second' >>"$R/a.rb"
    run bash -c "python3 '$SCRIPT' --base HEAD '$R' | jq -c '[.blocks[].text]'"
    [ "$output" = '["# second"]' ]
}
