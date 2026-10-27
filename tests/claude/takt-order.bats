#!/usr/bin/env bats

load ../test_helper

# takt-order スキルの補助スクリプトを検証する。
# HOME と HELLO_RUN_KB を tmpdir に向けるので、本物の kb と mise の node は触らない。

SKILL="home/dot_claude/skills/takt-order"

setup() {
    KB_SCRIPT="${REPO_ROOT}/${SKILL}/scripts/executable_kb.sh"
    TAKT_SCRIPT="${REPO_ROOT}/${SKILL}/scripts/executable_takt.sh"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    unset HELLO_RUN_KB
    cd "${BATS_TEST_TMPDIR}"
}

@test "takt-order: scripts have valid bash syntax" {
    run bash -n "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    run bash -n "${TAKT_SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "takt-order kb: fails when no kb exists" {
    run bash "${KB_SCRIPT}"
    [ "$status" -ne 0 ]
    [ ! -e "${HOME}/git_clone/local/kb/takt" ]
}

@test "takt-order kb: prefers ./kb symlink of the hello-run session" {
    mkdir -p real-kb "${HOME}/git_clone/local/kb"
    ln -s real-kb kb
    run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == */real-kb/takt ]] || false
    [ ! -e "${HOME}/git_clone/local/kb/takt" ]
}

@test "takt-order kb: falls back to HELLO_RUN_KB then the default path" {
    mkdir -p env-kb "${HOME}/git_clone/local/kb"
    HELLO_RUN_KB="${BATS_TEST_TMPDIR}/env-kb" run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == */env-kb/takt ]] || false
    run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == */git_clone/local/kb/takt ]] || false
}

@test "takt-order kb: creates the layout from templates and keeps existing files" {
    mkdir -p kb
    run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    for d in workflows orders facets/knowledge facets/policies facets/instructions \
             facets/personas facets/output-contracts; do
        [ -d "kb/takt/${d}" ]
    done
    # 空のディレクトリも autosave の push 先に残るように .gitkeep を置く
    [ -f kb/takt/orders/.gitkeep ]
    [ -f kb/takt/README.md ]
    [ -f kb/takt/playbook.md ]
    # 2 回目は育った playbook を雛形で上書きしない
    echo "### grown" >> kb/takt/playbook.md
    run bash "${KB_SCRIPT}"
    [ "$status" -eq 0 ]
    grep -q '^### grown$' kb/takt/playbook.md
}

@test "takt-order takt: --root picks the newest node that has takt" {
    export TAKT_NODE_INSTALLS="${BATS_TEST_TMPDIR}/node"
    mkdir -p "${TAKT_NODE_INSTALLS}/22.9.0/lib/node_modules/takt" \
             "${TAKT_NODE_INSTALLS}/22.23.2/lib/node_modules/takt" \
             "${TAKT_NODE_INSTALLS}/24.1.0/lib/node_modules/other"
    run bash "${TAKT_SCRIPT}" --root
    [ "$status" -eq 0 ]
    [ "$output" = "${TAKT_NODE_INSTALLS}/22.23.2/lib/node_modules/takt" ]
}

@test "takt-order takt: falls back to mise exec when the shim fails" {
    export TAKT_NODE_INSTALLS="${BATS_TEST_TMPDIR}/node"
    mkdir -p "${TAKT_NODE_INSTALLS}/22.23.2/lib/node_modules/takt" "${BATS_TEST_TMPDIR}/bin"
    # cwd で node が決まらないときの mise shim を真似る
    printf '#!/bin/sh\necho "mise ERROR No version is set for shim: takt" >&2\nexit 1\n' \
        > "${BATS_TEST_TMPDIR}/bin/takt"
    printf '#!/bin/sh\necho "mise $*"\n' > "${BATS_TEST_TMPDIR}/bin/mise"
    chmod +x "${BATS_TEST_TMPDIR}/bin/takt" "${BATS_TEST_TMPDIR}/bin/mise"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "${TAKT_SCRIPT}" workflow doctor x.yaml
    [ "$status" -eq 0 ]
    [ "$output" = "mise exec node@22.23.2 -- takt workflow doctor x.yaml" ]
}
