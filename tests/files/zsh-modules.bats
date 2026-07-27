#!/usr/bin/env bats

load ../test_helper

# 分割した zsh モジュールの構文と、代表的な定義を検証する。
# tools.zsh は compdef(要 compinit) や `mise activate` を含むため単体 source はせず zsh -n のみ。

DIR="home/dot_config/zsh"

setup() {
    command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
}

@test "options.zsh: valid zsh syntax" {
    run zsh -n "${REPO_ROOT}/${DIR}/options.zsh"
    [ "$status" -eq 0 ]
}

@test "aliases.zsh: valid zsh syntax" {
    run zsh -n "${REPO_ROOT}/${DIR}/aliases.zsh"
    [ "$status" -eq 0 ]
}

@test "tools.zsh: valid zsh syntax" {
    run zsh -n "${REPO_ROOT}/${DIR}/tools.zsh"
    [ "$status" -eq 0 ]
}

@test "aliases.zsh: sourcing defines representative aliases" {
    run zsh -c "source '${REPO_ROOT}/${DIR}/aliases.zsh'; alias g >/dev/null && alias gg >/dev/null && echo OK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
