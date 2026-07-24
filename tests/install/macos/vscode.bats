#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/vscode.sh"

@test "vscode.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "vscode.sh: sourcing defines install_extensions / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_extensions main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_extensions"* ]]
    [[ "$output" == *"main"* ]]
}

@test "vscode.sh: extension list exists" {
    [ -f "${REPO_ROOT}/install/macos/vscode-extensions.txt" ]
}

@test "vscode.sh: skips safely when code CLI is absent" {
    run env -i HOME="${HOME}" bash "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
}
