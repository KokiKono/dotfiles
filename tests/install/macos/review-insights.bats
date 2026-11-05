#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/review-insights.sh"

setup() {
    export RI_PLIST="${BATS_TEST_TMPDIR}/agent.plist"
    export CI=1
}

@test "review-insights.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "review-insights.sh: skips on CI" {
    run bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]] || false
}

@test "review-insights.sh: registers the agent only when it is not loaded" {
    STUB="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${STUB}"
    printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n[[ "$1" == print ]] && exit 1\nexit 0\n' \
        "${BATS_TEST_TMPDIR}/launchctl.log" >"${STUB}/launchctl"
    chmod +x "${STUB}/launchctl"
    touch "${RI_PLIST}"
    run env -u CI PATH="${STUB}:${PATH}" bash -c "source '${REPO_ROOT}/${SCRIPT}'; load_agent"
    [ "$status" -eq 0 ]
    grep -qxF "bootstrap gui/$(id -u) ${RI_PLIST}" "${BATS_TEST_TMPDIR}/launchctl.log"
}

@test "review-insights.sh: is chained from chezmoi's install script" {
    grep -q 'macos/review-insights.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}
