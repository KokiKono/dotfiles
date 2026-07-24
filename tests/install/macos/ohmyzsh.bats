#!/usr/bin/env bats

load ../../test_helper

SCRIPT="install/macos/ohmyzsh.sh"

@test "ohmyzsh.sh: valid bash syntax" {
    run bash -n "${REPO_ROOT}/${SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "ohmyzsh.sh: sourcing defines install_ohmyzsh / main" {
    run bash -c "source '${REPO_ROOT}/${SCRIPT}'; declare -F install_ohmyzsh main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"install_ohmyzsh"* ]]
    [[ "$output" == *"main"* ]]
}

@test "ohmyzsh.sh: skips install when .oh-my-zsh already exists" {
    tmphome="$(mktemp -d)"
    mkdir -p "${tmphome}/.oh-my-zsh"
    run bash -c "HOME='${tmphome}' bash '${REPO_ROOT}/${SCRIPT}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"スキップ"* ]]
    rm -rf "${tmphome}"
}
