#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/kb.sh"

setup() {
    export GIT_CONFIG_GLOBAL="${BATS_TEST_TMPDIR}/gitconfig"
    printf '[user]\n\tname = t\n\temail = t@example.com\n[init]\n\tdefaultBranch = master\n' \
        >"${GIT_CONFIG_GLOBAL}"
    export KB_DIR="${BATS_TEST_TMPDIR}/local/kb"
    export KB_REMOTE="${BATS_TEST_TMPDIR}/remote/kb.git"
    export KB_PLIST="${BATS_TEST_TMPDIR}/agent.plist"
    export CI=1
}

@test "kb.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "kb.sh: sourcing defines init_remote / init_clone / seed / load_agent / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F init_remote init_clone seed load_agent main"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 5 ]
}

@test "kb.sh: creates the bare remote and a seeded clone on main" {
    # init.defaultBranch が master のマシンでも main に揃うこと
    run bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [ -f "${KB_REMOTE}/HEAD" ]
    [ -f "${KB_DIR}/CLAUDE.md" ]
    [ -f "${KB_DIR}/.gitignore" ]
    [ -d "${KB_DIR}/issues" ]
    git -C "${KB_REMOTE}" show main:CLAUDE.md >/dev/null
    [ "$(git -C "${KB_DIR}" rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "kb.sh: rerunning keeps what kb has grown" {
    # 雛形は初回だけ。育てた CLAUDE.md を上書きしない
    bash "${REPO_ROOT}/${SCRIPT}"
    echo "育てた規約" >"${KB_DIR}/CLAUDE.md"
    run bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [ "$(cat "${KB_DIR}/CLAUDE.md")" = "育てた規約" ]
}

@test "kb.sh: the seed CLAUDE.md tells claude to leave git to autosave" {
    # 複数セッションが同じ clone に書くので、git を触るのは autosave だけにしている
    grep -q 'git を操作しない' "${REPO_ROOT}/install/macos/kb-seed/CLAUDE.md"
    grep -q 'autosave.sh' "${REPO_ROOT}/install/macos/kb-seed/CLAUDE.md"
}

@test "kb.sh: registers the autosave agent only when it is not loaded" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n[[ "$1" == print ]] && exit 1\nexit 0\n' \
        "${BATS_TEST_TMPDIR}/launchctl.log" >"${STUB}/launchctl"
    chmod +x "${STUB}/launchctl"
    touch "${KB_PLIST}"
    run env -u CI PATH="${STUB}:${PATH}" bash -c "source '${REPO_ROOT}/${SCRIPT}'; load_agent"
    [ "$status" -eq 0 ]
    grep -qxF "bootstrap gui/$(id -u) ${KB_PLIST}" "${BATS_TEST_TMPDIR}/launchctl.log"
}

@test "kb.sh: is chained from chezmoi's install script" {
    grep -q 'macos/kb.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}
