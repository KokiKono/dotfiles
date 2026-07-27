#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/mise.sh"

@test "mise.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "mise.sh: sourcing defines install_mise_tools / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_mise_tools main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_mise_tools"* ]]
    [[ "$output" == *"main"* ]]
}

@test "mise.sh: skips safely when mise is absent (empty PATH)" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
}
