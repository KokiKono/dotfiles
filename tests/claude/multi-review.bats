#!/usr/bin/env bats

load ../test_helper

# multi-review スキルの multi-review.sh（3 つの CLI での並列レビューとまとめ）を検証する。
# claude / agy（gemini）/ grok は PATH のスタブに置き換え、受け取った標準入力と引数を記録させる。

setup() {
    SCRIPT="${REPO_ROOT}/home/dot_claude/skills/multi-review/scripts/executable_multi-review.sh"
    R="${BATS_TEST_TMPDIR}/repo"
    BIN="${BATS_TEST_TMPDIR}/bin"
    OUT="${BATS_TEST_TMPDIR}/out"
    mkdir -p "$BIN"
    git init -q -b main "$R"
    git -C "$R" config user.name t
    git -C "$R" config user.email t@example.com
    git -C "$R" config commit.gpgsign false
    echo 'a = 1' >"$R/a.rb"
    git -C "$R" add -A
    git -C "$R" commit -q -m init
    git -C "$R" update-ref refs/remotes/origin/main HEAD
    echo 'b = 2' >>"$R/a.rb"
    for n in claude agy grok; do stub "$n" "echo \"### [重大度: 高] [確度: 高] a.rb:2 ${n} の指摘\""; done
    export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    cd "$R"
}

# bats は fd 3 が閉じるまで待つので、スタブの sleep などに引き継がせない
mr() { bash "$SCRIPT" "$@" 3>&-; }

# スタブ: 受け取った標準入力を <name>.in（呼ばれるたびに上書き）、引数を <name>.args に残して $2 を実行する
stub() {
    cat >"$BIN/$1" <<SH
#!/bin/bash
cat >"$BIN/$1.in"
echo "\$@" >"$BIN/$1.args"
$2
SH
    chmod +x "$BIN/$1"
}

@test "multi-review: sends the branch diff to every reviewer and prints the merged report" {
    stub claude 'if grep -q "1 つのレポートにまとめて" "'"$BIN"'/claude.in"; then echo MERGED; else echo "### claude の指摘"; fi'
    run mr --out "$OUT"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/report.md")" = MERGED ]
    [[ "$output" == *MERGED* ]] || false
    # 各レビュアーの出力が残り、まとめのプロンプトに全員分が入っていること
    for n in claude gemini grok; do
        [ "$(cat "$OUT/$n.status")" = ok ]
        grep -q "<review reviewer=\"$n\" status=\"ok\">" "$OUT/merge-prompt.md"
    done
    grep -qF 'agy の指摘' "$OUT/merge-prompt.md"
    # 差分は既定ブランチとの merge-base からで、未コミットの変更も入ること
    grep -qF '+b = 2' "$OUT/prompt.md"
    # agy にはプロンプトを引数で渡す
    grep -qF '+b = 2' "$BIN/agy.args"
    # 差分に ``` が入っていてもプロンプトの区切りが崩れないよう、タグで囲む
    grep -qx '<diff>' "$OUT/prompt.md"
    [ "$(tail -1 "$OUT/prompt.md")" = '</diff>' ]
}

@test "multi-review: untracked files are sent only with --untracked" {
    echo 'c = 3' >"$R/new.rb"
    # 既定では送らず、送っていないファイルの名前を知らせる
    run mr --out "$OUT" --only grok --no-merge
    [ "$status" -eq 0 ]
    [[ "$output" == *"--untracked"*"new.rb"* ]] || false
    run grep -qF '+c = 3' "$OUT/prompt.md"
    [ "$status" -ne 0 ]
    run mr --out "$OUT" --only grok --no-merge --untracked
    [ "$status" -eq 0 ]
    grep -qF '+c = 3' "$OUT/prompt.md"
    # 本物の index には intent-to-add が残らず、未追跡のままであること
    [ "$(git status --porcelain -- new.rb)" = '?? new.rb' ]
}

@test "multi-review: grok gets the prompt as a file with read-only tools" {
    run mr --out "$OUT" --only grok --no-merge
    [ "$status" -eq 0 ]
    # grok が使えるツールは読み込みの 3 つだけ
    grep -qF -- "--tools Read,Grep,Glob --permission-mode dontAsk" "$BIN/grok.args"
    grep -qF -- "--prompt-file $OUT/prompt.md" "$BIN/grok.args"
}

@test "multi-review: gemini runs agy with read-only permissions" {
    run mr --out "$OUT" --only gemini --no-merge
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/gemini.status")" = ok ]
    grep -qF '"allow":["read_file"' "$BIN/agy.args"
    grep -qF '"deny":["write_file","edit_file"]' "$BIN/agy.args"
}

@test "multi-review: claude reviewer may read files but not edit them" {
    run mr --out "$OUT" --only claude --no-merge
    [ "$status" -eq 0 ]
    # claude のレビュアーが使えるツールは読み込みの 3 つだけで、MCP も外す
    grep -qF -- "--tools Read,Grep,Glob --strict-mcp-config" "$BIN/claude.args"
    # プロンプトは標準入力で受け取る
    grep -qF '+b = 2' "$BIN/claude.in"
}

@test "multi-review: the merging claude gets no tools at all" {
    run mr --out "$OUT" --only gemini
    [ "$status" -eq 0 ]
    # 最後に呼ばれた claude がまとめ役
    [ "$(cat "$BIN/claude.args")" = "-p --tools  --strict-mcp-config" ]
}

@test "multi-review: a failing or missing reviewer does not stop the others" {
    stub agy 'echo boom >&2; exit 3'
    rm "$BIN/grok"
    run mr --out "$OUT"
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT/claude.status")" = ok ]
    [[ "$(cat "$OUT/gemini.status")" == "failed: exit 3"* ]] || false
    [[ "$(cat "$OUT/grok.status")" == skipped* ]] || false
    # まとめ役には失敗とスキップも状態として渡し、レポートの表に出させる
    grep -qF '<review reviewer="gemini" status="failed: exit 3' "$OUT/merge-prompt.md"
    grep -qF '<review reviewer="grok" status="skipped' "$OUT/merge-prompt.md"
    # skipped の理由には、探したコマンドの名前を出す
    rm "$BIN/agy"
    run mr --out "$OUT" --only gemini,claude --no-merge
    [ "$(cat "$OUT/gemini.status")" = "skipped: agy が PATH に無い" ]
}

@test "multi-review: fails when every reviewer fails" {
    for n in claude agy grok; do stub "$n" 'exit 1'; done
    run mr --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"全レビュアーが失敗"* ]] || false
}

@test "multi-review: a reviewer over the time limit is stopped and reported as failed" {
    stub grok 'exec sleep 30'
    SECONDS=0
    run mr --out "$OUT" --timeout 1 --no-merge
    [ "$status" -eq 0 ]
    [ "$SECONDS" -lt 15 ]
    [ "$(cat "$OUT/grok.status")" = "failed: timeout（1 秒）" ]
}

@test "multi-review: rejects a non-numeric timeout" {
    run mr --out "$OUT" --timeout abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"--timeout"* ]] || false
}

@test "multi-review: fails without a diff" {
    git checkout -q -- a.rb
    run mr --out "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"差分がありません"* ]] || false
}

@test "multi-review: --pr reviews the gh pr diff and --focus reaches the prompt" {
    stub gh 'printf "%s\n" "--- a/x" "+++ b/x" "+from pr"'
    run mr --out "$OUT" --pr 12 --focus '権限まわり' --only gemini --no-merge
    [ "$status" -eq 0 ]
    [ "$(cat "$BIN/gh.args")" = "pr diff 12" ]
    grep -qF '+from pr' "$OUT/prompt.md"
    grep -qF '特に見てほしい観点: 権限まわり' "$OUT/prompt.md"
    grep -qF 'PR 12' "$OUT/prompt.md"
}

@test "multi-review: a reviewer that exits 0 with no output is reported as empty" {
    stub agy 'exit 0'
    run mr --out "$OUT" --only gemini,claude --no-merge
    [ "$status" -eq 0 ]
    [[ "$(cat "$OUT/gemini.status")" == "failed: 出力が空"* ]] || false
}

@test "multi-review: output from an earlier run in the same --out is not merged again" {
    run mr --out "$OUT"
    [ "$status" -eq 0 ]
    rm "$BIN/grok"
    run mr --out "$OUT"
    [ "$status" -eq 0 ]
    run grep -qF 'grok の指摘' "$OUT/merge-prompt.md"
    [ "$status" -ne 0 ]
}

@test "multi-review: an option without its value is rejected with a message" {
    run mr --out "$OUT" --pr
    [ "$status" -ne 0 ]
    [[ "$output" == *"--pr に値を渡してください"* ]] || false
}

@test "multi-review: stopping the script also stops the running reviewers" {
    stub grok 'exec sleep 31'
    bash "$SCRIPT" --out "$OUT" --only grok --no-merge 3>&- 2>/dev/null &
    pid=$!
    for _ in $(seq 50); do pgrep -f 'sleep 31' >/dev/null && break; sleep 0.1; done
    pgrep -f 'sleep 31' >/dev/null
    kill -TERM "$pid"
    wait "$pid" || true
    sleep 0.5
    run pgrep -f 'sleep 31'
    [ "$status" -ne 0 ]
}
