#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/brew.sh"

@test "brew.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "brew.sh: sourcing defines functions without side effects" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_homebrew brew_bundle main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_homebrew"* ]]
    [[ "$output" == *"brew_bundle"* ]]
    [[ "$output" == *"main"* ]]
}

@test "brew.sh: references the Brewfile" {
    run grep -q 'REPO_ROOT}/Brewfile' "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}
