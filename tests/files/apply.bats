#!/usr/bin/env bats

load ../test_helper

# 使い捨ての HOME に chezmoi apply し、期待どおりのファイルが展開されるか検証する。
# install スクリプト（brew 等）は副作用が大きいので --exclude scripts で除外する。

setup() {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    TESTHOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${TESTHOME}/.config/chezmoi"
    CFG="${TESTHOME}/.config/chezmoi/chezmoi.yaml"
    CM=(chezmoi
        --source "${REPO_ROOT}"
        --destination "${TESTHOME}"
        --config "${CFG}"
        --persistent-state "${TESTHOME}/state.boltdb"
        --cache "${TESTHOME}/.cache")
    "${CM[@]}" init --promptDefaults --no-tty
    "${CM[@]}" apply --exclude scripts --force
}

@test "apply: ~/.zshrc is deployed and identical to source" {
    [ -f "${TESTHOME}/.zshrc" ]
    diff "${REPO_ROOT}/home/dot_zshrc" "${TESTHOME}/.zshrc"
}

@test "apply: ~/.gitconfig is deployed with name/email filled in" {
    [ -f "${TESTHOME}/.gitconfig" ]
    grep -q "name = KokiKono" "${TESTHOME}/.gitconfig"
    grep -q "email = kono.koki.pg@gmail.com" "${TESTHOME}/.gitconfig"
    # no unrendered template syntax left
    run grep -F '{{' "${TESTHOME}/.gitconfig"
    [ "$status" -ne 0 ]
}

@test "apply: ~/.gitignore_global is deployed" {
    [ -f "${TESTHOME}/.gitignore_global" ]
    grep -q ".DS_Store" "${TESTHOME}/.gitignore_global"
}

@test "apply: VS Code settings.json / keybindings.json are deployed" {
    [ -f "${TESTHOME}/Library/Application Support/Code/User/settings.json" ]
    [ -f "${TESTHOME}/Library/Application Support/Code/User/keybindings.json" ]
}

@test "apply: mise config.toml is deployed with pinned tools" {
    [ -f "${TESTHOME}/.config/mise/config.toml" ]
    grep -q 'node = "22.16.0"' "${TESTHOME}/.config/mise/config.toml"
    grep -q 'python = "3.11.6"' "${TESTHOME}/.config/mise/config.toml"
    grep -q 'java = "temurin-11"' "${TESTHOME}/.config/mise/config.toml"
}

@test "apply: zsh modules are deployed" {
    [ -f "${TESTHOME}/.config/zsh/options.zsh" ]
    [ -f "${TESTHOME}/.config/zsh/aliases.zsh" ]
    [ -f "${TESTHOME}/.config/zsh/tools.zsh" ]
    [ -f "${TESTHOME}/.config/zsh/git-worktree.zsh" ]
}

@test "apply: zshrc is a thin loader sourcing the modules" {
    grep -q 'source $ZSH/oh-my-zsh.sh' "${TESTHOME}/.zshrc"
    grep -q 'ZSH_CONF_DIR' "${TESTHOME}/.zshrc"
    grep -q 'git-worktree.zsh' "${TESTHOME}/.zshrc"
}

@test "apply: mise activate lives in tools module (not inline in zshrc)" {
    grep -q 'mise activate zsh' "${TESTHOME}/.config/zsh/tools.zsh"
}

@test "apply: no legacy version-manager init anywhere in zshrc + modules" {
    # anyenv/goenv/pyenv/jenv の init や nodenv init が混入していないこと
    run grep -rE 'anyenv init|goenv init|pyenv init|jenv init|nodenv init' \
        "${TESTHOME}/.zshrc" "${TESTHOME}/.config/zsh"
    [ "$status" -ne 0 ]
}
