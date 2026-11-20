#!/usr/bin/env bats

load ../test_helper

# mutation-check スキルの run_mutations.py と kb.sh を検証する。
# テストの道具は、対象ファイルの中身で結果を変えるスタブ（fake-runner）に置き換える。

SKILL="home/dot_claude/skills/mutation-check"

setup() {
    RUN="${REPO_ROOT}/${SKILL}/scripts/executable_run_mutations.py"
    GEN="${REPO_ROOT}/${SKILL}/scripts/executable_gen_mutations.py"
    KB_SCRIPT="${REPO_ROOT}/${SKILL}/scripts/executable_kb.sh"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    unset HELLO_RUN_KB
    cd "${BATS_TEST_TMPDIR}"

    printf 'limit = 4\nkeep = true\n' > target.txt
    # target.txt の中身で結果を変える: limit = 5 で失敗、SYNTAX で読み込み失敗、SLOW で固まる
    cat > fake-runner <<'EOF'
#!/usr/bin/env bash
if grep -q 'SYNTAX' target.txt; then
    echo "0 examples, 0 failures, 1 error occurred outside of examples"; exit 1
fi
if grep -q 'CRASH' target.txt; then echo "boom"; exit 1; fi
if grep -q 'SLOW' target.txt; then sleep 45; fi
if grep -q 'limit = 5' target.txt; then echo "3 examples, 1 failure"; exit 1; fi
echo "3 examples, 0 failures"
EOF
    chmod +x fake-runner
}

# definition <mutations の JSON 配列> [追加のキーの JSON]
definition() {
    # 既定値を ${2:-{\}} と書くと、bash 3.2（CI の macOS）では \ が残って JSON にならない
    local extra='{}'
    [ -z "${2:-}" ] || extra=$2
    jq -n --argjson m "$1" --argjson extra "$extra" \
        '{runner: "rspec", command: ["./fake-runner"], mutations: $m} + $extra' > def.json
}

mutation() {
    jq -cn --arg l "$1" --arg o "$2" --arg n "$3" '{label: $l, file: "target.txt", old: $o, new: $n}'
}

status_of() {
    jq -r --arg l "$1" '.results[] | select(.label == $l) | .status' out.json
}

@test "mutation-check: scripts have valid syntax" {
    # py_compile はソースの隣に __pycache__ を作り、chezmoi がそれを配ってしまうので使わない
    run python3 -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' "${RUN}" "${GEN}"
    [ "$status" -eq 0 ]
    run bash -n "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "mutation-check run: separates killed, survived and broken mutations" {
    definition "[$(mutation killed 'limit = 4' 'limit = 5'),$(mutation survived 'keep = true' 'keep = false'),$(mutation syntax 'keep = true' 'SYNTAX'),$(mutation crash 'keep = true' 'CRASH')]"
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(status_of killed)" = "killed" ]
    [ "$(status_of survived)" = "survived" ]
    # 読み込みで落ちたもの・集計の行が出ないものは検出に数えない
    [ "$(status_of syntax)" = "broken" ]
    [ "$(status_of crash)" = "broken" ]
    [ "$(jq -r '.counts.killed' out.json)" = "1" ]
    [[ "$output" == *"検出 1 / 2"* ]] || false
    [[ "$output" == *"壊れた 2"* ]] || false
}

@test "mutation-check run: restores the file after every mutation" {
    cp target.txt before.txt
    definition "[$(mutation a 'limit = 4' 'limit = 5'),$(mutation b 'keep = true' 'SYNTAX')]"
    run python3 "${RUN}" def.json
    [ "$status" -eq 0 ]
    cmp target.txt before.txt
}

@test "mutation-check run: stops when the baseline fails" {
    printf 'limit = 5\n' > target.txt
    definition "[$(mutation a 'limit = 5' 'limit = 6')]"
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -ne 0 ]
    [ ! -e out.json ]
    [ "$(cat target.txt)" = "limit = 5" ]
}

@test "mutation-check run: stops when the baseline output has no summary line" {
    definition "[$(mutation a 'limit = 4' 'limit = 5')]" '{"summary_pattern": "Tests: \\d+ total"}'
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"集計の行"* ]] || false
}

@test "mutation-check run: marks an ambiguous or missing old as invalid without running" {
    printf 'limit = 4\nlimit = 4\n' > target.txt
    definition "[$(mutation twice 'limit = 4' 'limit = 5'),$(mutation none 'nope' 'x'),$(mutation same 'limit' 'limit')]"
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(status_of twice)" = "invalid" ]
    [ "$(status_of none)" = "invalid" ]
    [ "$(status_of same)" = "invalid" ]
    [ "$(printf 'limit = 4\nlimit = 4\n')" = "$(cat target.txt)" ]
}

@test "mutation-check run: times out a hanging run and restores the file" {
    cp target.txt before.txt
    definition "[$(mutation slow 'keep = true' 'SLOW')]" '{"timeout": 2}'
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(status_of slow)" = "timeout" ]
    cmp target.txt before.txt
}

@test "mutation-check run: restores a CRLF file byte for byte" {
    printf 'limit = 4\r\nkeep = true\r\n' > target.txt
    cp target.txt before.txt
    definition "[$(mutation a 'keep = true' 'keep = false')]"
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(status_of a)" = "survived" ]
    cmp target.txt before.txt
}

@test "mutation-check run: rejects a timeout that is not a positive number" {
    definition "[$(mutation a 'limit = 4' 'limit = 5')]" '{"timeout": 0}'
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"timeout"* ]] || false
    definition "[$(mutation a 'limit = 4' 'limit = 5')]" '{"timeout": "300"}'
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"timeout"* ]] || false
}

@test "mutation-check run: writes the results so far after every mutation" {
    definition "[$(mutation a 'limit = 4' 'limit = 5'),$(mutation slow 'keep = true' 'SLOW')]" '{"timeout": 20}'
    python3 "${RUN}" def.json --out out.json &
    pid=$!
    for _ in $(seq 50); do [ -s out.json ] && break; sleep 0.2; done
    [ "$(status_of a)" = "killed" ]
    # 途中で止めても、書き換えは残らない
    kill -HUP "$pid"
    wait "$pid" || true
    grep -q 'keep = true' target.txt
}

@test "mutation-check run: --only and --survivors-of narrow the mutations" {
    definition "[$(mutation 'a/killed' 'limit = 4' 'limit = 5'),$(mutation 'b/survived' 'keep = true' 'keep = false')]"
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    run python3 "${RUN}" def.json --only a/ --out only.json
    [ "$(jq -r '[.results[].label] | join(",")' only.json)" = "a/killed" ]
    run python3 "${RUN}" def.json --survivors-of out.json --out again.json
    [ "$(jq -r '[.results[].label] | join(",")' again.json)" = "b/survived" ]
}

@test "mutation-check run: rejects a broken definition before touching files" {
    echo '{"runner": "rspec", "command": ["./fake-runner"], "mutations": [{"label": "x"}]}' > def.json
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutations[0]"* ]] || false
    definition "[$(mutation dup 'limit = 4' 'limit = 5'),$(mutation dup 'keep = true' 'x')]"
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"重複"* ]] || false
    echo '{"command": ["./fake-runner"], "mutations": [{"label": "x", "file": "f", "old": "a", "new": "b"}]}' > def.json
    run python3 "${RUN}" def.json
    [ "$status" -ne 0 ]
    [[ "$output" == *"summary_pattern"* ]] || false
}

@test "mutation-check run: a mutation with offset rewrites only that position" {
    printf 'limit = 4\nother = 4\nlimit = 4\n' > target.txt
    cat > fake-runner <<'EOF'
#!/usr/bin/env bash
if [ "$(sed -n 3p target.txt)" = "limit = 5" ] && [ "$(sed -n 1p target.txt)" = "limit = 4" ]; then
    echo "3 examples, 1 failure"; exit 1
fi
echo "3 examples, 0 failures"
EOF
    jq -n '{runner: "rspec", command: ["./fake-runner"], mutations: [
        {label: "third", file: "target.txt", offset: 28, old: "4", new: "5"},
        {label: "stale", file: "target.txt", offset: 27, old: "4", new: "5"},
        {label: "beyond", file: "target.txt", offset: 99, old: "4", new: "5"}]}' > def.json
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(status_of third)" = "killed" ]
    # その位置の中身が定義と違う（コードを直して定義が古くなった）ときは流さない
    [ "$(status_of stale)" = "invalid" ]
    [ "$(status_of beyond)" = "invalid" ]
    [ "$(sed -n 3p target.txt)" = "limit = 4" ]
}

@test "mutation-check run: without a timeout, the limit follows the baseline run" {
    cp target.txt before.txt
    definition "[$(mutation slow 'keep = true' 'SLOW')]"
    MUTATION_CHECK_MIN_TIMEOUT=1 run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    # 基準は一瞬で終わるので、固まる変異は下限（ここでは 1 秒）で切られる
    [ "$(status_of slow)" = "timeout" ]
    cmp target.txt before.txt
}

# 差分のあるリポジトリを作る。base は最初のコミット
gen_repo() {
    git init -q repo
    cd repo
    mkdir -p app spec src
    printf 'class A\n  OLD = 1 > 0\nend\n' > app/a.rb
    git add -A
    git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm init
}

# 正規表現版（JS / TS と、Prism の無い環境の Ruby）を確かめるので、Ruby も --no-ast で作る
gen_labels() {
    python3 "${GEN}" --base HEAD --no-ast "$@" | jq -r '.mutations[].label'
}

# 構文木版。Prism を読める ruby（3.3 以上）が無い環境では飛ばす
gen_ast() {
    ruby -rprism -e 1 2>/dev/null || skip "ruby with prism is not available"
    python3 "${GEN}" --base HEAD "$@" > cand.json
}

ast_labels() {
    jq -r '.mutations[].label' cand.json
}

@test "mutation-check gen: mutates only the changed lines" {
    gen_repo
    printf 'class A\n  OLD = 1 > 0\n  ok = days >= LIMIT && !done\nend\n' > app/a.rb
    run gen_labels
    [ "$status" -eq 0 ]
    [[ "$output" == *"app/a.rb:3:"*">= → >"* ]] || false
    [[ "$output" == *"app/a.rb:3:"*"&& → ||"* ]] || false
    [[ "$output" == *"app/a.rb:3:"*"! → （消す）"* ]] || false
    # 変えていない 2 行目は対象にしない
    [[ "$output" != *"app/a.rb:2:"* ]] || false
}

@test "mutation-check gen: skips strings, comments and test files" {
    gen_repo
    printf 'class A\n  OLD = 1 > 0\n  name = "a >= b && 3" # x == 4\nend\n' > app/a.rb
    printf 'x = 1 >= 2\n' > spec/a_spec.rb
    printf 'const x = 1 >= 2;\n' > src/a.test.ts
    run gen_labels
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "mutation-check gen: skips block comments and imports, and survives odd diff lines" {
    gen_repo
    printf '/**\n * Returns true if x >= 3\n */\nimport * as R from "r";\nlet i = 0;\n' > src/c.ts
    git add -A
    git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm c
    # `++ i` で始まる行は diff で `+++ i` になる。ヘッダーと取り違えると後ろの変更を落とす
    printf '/**\n * Returns false if x >= 4\n */\nimport * as S from "s";\nlet i = 0;\n++ i;\nconst ok = i >= 2;\n' > src/c.ts
    run gen_labels
    [ "$status" -eq 0 ]
    [[ "$output" == *"src/c.ts:7:"*">= → >"* ]] || false
    [[ "$output" != *"src/c.ts:2:"* ]] || false
    [[ "$output" != *"src/c.ts:4:"* ]] || false
}

@test "mutation-check gen: covers untracked files and both languages" {
    gen_repo
    printf 'def call(xs)\n  return if xs.empty?\n  xs.map(&:day).uniq.size - 1\nend\n' > app/b.rb
    printf 'const f = (xs: Array<number>) => {\n  if (xs.length === 0) return null;\n  return xs.some((x) => x > 3);\n};\n' > src/b.tsx
    run gen_labels
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto/行の削除: app/b.rb:2:"* ]] || false
    [[ "$output" == *"app/b.rb:3:"*".uniq → （消す）"* ]] || false
    [[ "$output" == *"src/b.tsx:2:"*"=== → !=="* ]] || false
    [[ "$output" == *"src/b.tsx:3:"*".some( → .every("* ]] || false
    # 総称型の <number> やアロー関数の => は比較として拾わない
    [[ "$output" != *"src/b.tsx:1:"* ]] || false
    # パスで絞れる
    run gen_labels app
    [[ "$output" != *"src/b.tsx"* ]] || false
}

@test "mutation-check gen: its output runs through run_mutations as is" {
    gen_repo
    printf 'class A\n  OLD = 1 > 0\n  LIMIT = 4\nend\n' > app/a.rb
    python3 "${GEN}" --base HEAD --out cand.json
    printf '#!/usr/bin/env bash\nif grep -q "LIMIT = 5" app/a.rb; then echo "1 example, 1 failure"; exit 1; fi\necho "1 example, 0 failures"\n' > runner
    chmod +x runner
    jq '{runner: "rspec", command: ["./runner"]} + .' cand.json > def.json
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.counts.killed' out.json)" = "1" ]
    grep -q 'LIMIT = 4' app/a.rb
}

@test "mutation-check gen ruby: mutates expressions from the syntax tree" {
    gen_repo
    cat > app/a.rb <<'EOF'
class A
  OLD = 1 > 0
  def call(xs)
    return if xs.empty?
    ids = @ids || all_ids
    days = xs.map(&:day).uniq.size - 1
    log(days)
    user&.name if days >= LIMIT
  end
end
EOF
    gen_ast
    run ast_labels
    [[ "$output" == *"auto/文の削除: app/a.rb:4:"*"return if xs.empty?"* ]] || false
    [[ "$output" == *"auto/条件を true に: app/a.rb:4:"* ]] || false
    [[ "$output" == *"auto/条件を false に: app/a.rb:8:"* ]] || false
    [[ "$output" == *"auto/論理（右だけ）: app/a.rb:5:"*"→ all_ids"* ]] || false
    [[ "$output" == *"auto/呼び出しの削除: app/a.rb:6:"*".uniq → （消す）"* ]] || false
    [[ "$output" == *"auto/nil の扱い: app/a.rb:8:"* ]] || false
    [[ "$output" == *"auto/比較: app/a.rb:8:"*">= → >"* ]] || false
    # 変えていない 2 行目は対象にしない。代入と定義は消さない（NameError でどのテストでも落ちるだけ）
    [[ "$output" != *"app/a.rb:2:"* ]] || false
    [[ "$output" != *"文の削除: app/a.rb:5:"* ]] || false
    [[ "$output" != *"文の削除: app/a.rb:3:"* ]] || false
    # label は重複しない
    [ -z "$(ast_labels | sort | uniq -d)" ]
}

@test "mutation-check gen ruby: ignores strings and comments, and emits only parsable mutations" {
    gen_repo
    cat > app/a.rb <<'EOF'
class A
  OLD = 1 > 0
  NAME = <<~TEXT # a == b
    x >= 1 && true
  TEXT
  def generic = [Array, Hash].first
end
EOF
    gen_ast
    run ast_labels
    [ "$output" = "auto/メソッド: app/a.rb:6:31 first → last" ]
    ruby -rprism -rjson -e '
      JSON.parse(File.read("cand.json"))["mutations"].each do |m|
        src = File.binread(m["file"])
        src[m["offset"], m["old"].bytesize] = m["new"].b
        exit 1 unless Prism.parse(src).success?
      end'
}

@test "mutation-check gen ruby: offsets survive multibyte text and run through run_mutations" {
    gen_repo
    printf 'class A\n  OLD = 1 > 0\n  # 上限は日本語のコメントの後ろ\n  LIMIT = 4\nend\n' > app/a.rb
    gen_ast
    printf '#!/usr/bin/env bash\nif grep -q "LIMIT = 5" app/a.rb; then echo "1 example, 1 failure"; exit 1; fi\necho "1 example, 0 failures"\n' > runner
    chmod +x runner
    jq '{runner: "rspec", command: ["./runner"]} + .' cand.json > def.json
    cp app/a.rb before.rb
    run python3 "${RUN}" def.json --out out.json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.counts.killed' out.json)" = "1" ]
    [ "$(jq -r '.counts.invalid' out.json)" = "0" ]
    cmp app/a.rb before.rb
    # コードを直して位置がずれた定義は流さない
    printf 'class A\n  LIMIT = 4\nend\n' > app/a.rb
    run python3 "${RUN}" def.json --out out.json
    [ "$(jq -r '.counts.invalid' out.json)" = "$(jq -r '.results | length' out.json)" ]
}

@test "mutation-check kb: fails when no kb exists" {
    run bash "${KB_SCRIPT}"
    [ "$status" -ne 0 ]
}

@test "mutation-check kb: prefers ./kb, then HELLO_RUN_KB, then the default path" {
    mkdir -p real-kb env-kb "${HOME}/git_clone/local/kb"
    run bash "${KB_SCRIPT}"
    [[ "$output" == */git_clone/local/kb/mutations ]] || false
    HELLO_RUN_KB="${BATS_TEST_TMPDIR}/env-kb" run bash "${KB_SCRIPT}"
    [[ "$output" == */env-kb/mutations ]] || false
    ln -s real-kb kb
    run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == */real-kb/mutations ]] || false
}

@test "mutation-check kb: creates the named directory and keeps an existing README" {
    mkdir -p kb/mutations
    echo mine > kb/mutations/README.md
    run bash "${KB_SCRIPT}" repo-123
    [ "$status" -eq 0 ]
    [[ "$output" == */kb/mutations/repo-123 ]] || false
    [ -d kb/mutations/repo-123 ]
    [ "$(cat kb/mutations/README.md)" = "mine" ]
    rm kb/mutations/README.md
    run bash "${KB_SCRIPT}"
    [ -f kb/mutations/README.md ]
}

@test "mutation-check kb: rejects names that escape the mutations directory" {
    mkdir -p kb
    run bash "${KB_SCRIPT}" ../issues
    [ "$status" -ne 0 ]
    run bash "${KB_SCRIPT}" a/b
    [ "$status" -ne 0 ]
}
