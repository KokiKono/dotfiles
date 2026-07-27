#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/nodenv.sh"

@test "nodenv.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "nodenv.sh: sourcing defines install_yarn_plugin / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_yarn_plugin main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_yarn_plugin"* ]]
    [[ "$output" == *"main"* ]]
}

@test "nodenv.sh: skips safely when nodenv is absent (empty PATH)" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
}
