#!/usr/bin/env bats

load ../test_helper

SRC="home/dot_config/kb/executable_autosave.sh"

setup() {
    AS="${REPO_ROOT}/${SRC}"
    # 署名を必須にした global 設定を置き、autosave が署名せずにコミットできることも確かめる
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
    printf '[user]\n\tname = t\n\temail = t@example.com\n[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n[init]\n\tdefaultBranch = main\n' \
        >"${GIT_CONFIG_GLOBAL}"
    REMOTE="${BATS_TEST_TMPDIR}/kb.git"
    export KB_DIR="${BATS_TEST_TMPDIR}/kb"
    git init -q --bare "${REMOTE}"
    git clone -q "${REMOTE}" "${KB_DIR}" 2>/dev/null
    git -C "${KB_DIR}" commit -q --allow-empty --no-gpg-sign -m init
    git -C "${KB_DIR}" push -q origin HEAD
}

@test "autosave.sh: valid bash syntax" {
    run bash -n "${AS}"
    [ "$status" -eq 0 ]
}

@test "autosave.sh: commits every change without signing and pushes" {
    mkdir -p "${KB_DIR}/issues/r-1"
    echo memo >"${KB_DIR}/issues/r-1/README.md"
    run bash "${AS}"
    [ "$status" -eq 0 ]
    [ -z "$(git -C "${KB_DIR}" status --porcelain)" ]
    [ "$(git -C "${REMOTE}" log -1 --format=%s main)" != "init" ]
    [ "$(git -C "${REMOTE}" show main:issues/r-1/README.md)" = "memo" ]
}

@test "autosave.sh: makes no commit when nothing changed" {
    before="$(git -C "${KB_DIR}" rev-parse HEAD)"
    run bash "${AS}"
    [ "$status" -eq 0 ]
    [ "$(git -C "${KB_DIR}" rev-parse HEAD)" = "${before}" ]
}

@test "autosave.sh: stays out of the way while git is busy" {
    # 手で git を操作している最中にコミットを挟むと、その操作を壊す
    echo memo >"${KB_DIR}/a.md"
    touch "${KB_DIR}/.git/index.lock"
    before="$(git -C "${KB_DIR}" rev-parse HEAD)"
    run bash "${AS}"
    [ "$status" -eq 0 ]
    [ "$(git -C "${KB_DIR}" rev-parse HEAD)" = "${before}" ]
}

@test "autosave.sh: exits quietly when kb does not exist" {
    run env KB_DIR="${BATS_TEST_TMPDIR}/none" bash "${AS}"
    [ "$status" -eq 0 ]
}
