#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/writing-retro.sh"

setup() {
    export RETRO_PLIST="${BATS_TEST_TMPDIR}/agent.plist"
    export CI=1
}

@test "writing-retro.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "writing-retro.sh: skips registration on CI" {
    touch "${RETRO_PLIST}"
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; load_agent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]] || false
}

@test "writing-retro.sh: skips when the plist is not deployed yet" {
    run env -u CI bash -c "source '${REPO_ROOT}/${SCRIPT}'; load_agent"
    [ "$status" -eq 0 ]
    [[ "$output" == *"未配備"* ]] || false
}

@test "writing-retro.sh: registers the agent only when it is not loaded" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n[[ "$1" == print ]] && exit 1\nexit 0\n' \
        "${BATS_TEST_TMPDIR}/launchctl.log" >"${STUB}/launchctl"
    chmod +x "${STUB}/launchctl"
    touch "${RETRO_PLIST}"
    run env -u CI PATH="${STUB}:${PATH}" bash -c "source '${REPO_ROOT}/${SCRIPT}'; load_agent"
    [ "$status" -eq 0 ]
    grep -qxF "bootstrap gui/$(id -u) ${RETRO_PLIST}" "${BATS_TEST_TMPDIR}/launchctl.log"
}

@test "writing-retro.sh: is chained from chezmoi's install script" {
    grep -q 'macos/writing-retro.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}
