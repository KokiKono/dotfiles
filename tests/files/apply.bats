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

@test "apply: my-voice skill is deployed with its references" {
    SKILL="${TESTHOME}/.claude/skills/my-voice"
    [ -f "${SKILL}/SKILL.md" ]
    [ -f "${SKILL}/references/slack-voice.md" ]
    [ -f "${SKILL}/references/formal-voice.md" ]
    [ -f "${SKILL}/references/pr-voice.md" ]
    # frontmatter があり、スキル一覧に載る description が入っていること
    grep -q '^name: my-voice$' "${SKILL}/SKILL.md"
    grep -q '^description: ' "${SKILL}/SKILL.md"
}

@test "apply: my-voice references contain no internal identifiers" {
    # public リポジトリなので実データの固有名詞・社内 URL が混入していないこと
    run grep -rniE 'gritinc|progrit|slack\.com/archives|app\.notion\.com|notion\.so|docs\.google\.com|drive\.google\.com' \
        "${TESTHOME}/.claude/skills/my-voice"
    [ "$status" -ne 0 ]
}

@test "apply: claude global settings are deployed as valid json" {
    [ -f "${TESTHOME}/.claude/settings.json" ]
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${TESTHOME}/.claude/settings.json"
    [ -f "${TESTHOME}/.claude/.mcp.json" ]
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${TESTHOME}/.claude/.mcp.json"
    [ -x "${TESTHOME}/.claude/statusline-command.sh" ]
}

@test "apply: claude hooks and scripts are deployed executable" {
    for h in review-before-pr.sh herdr-agent-state.sh cbm-code-discovery-gate \
             cbm-session-reminder cbm-subagent-reminder; do
        [ -x "${TESTHOME}/.claude/hooks/${h}" ]
    done
    # permissions マージ用スクリプトは python3 で構文が通ること
    for s in merge-local-permissions.py merge-worktree-permissions.py; do
        [ -f "${TESTHOME}/.claude/scripts/${s}" ]
        python3 -m py_compile "${TESTHOME}/.claude/scripts/${s}"
    done
}

@test "apply: settings.json hooks point at deployed files" {
    # settings.json が参照するフック/スクリプトが実際に配置されていること
    for f in .claude/hooks/review-before-pr.sh .claude/hooks/herdr-agent-state.sh \
             .claude/hooks/cbm-code-discovery-gate .claude/hooks/cbm-session-reminder \
             .claude/hooks/cbm-subagent-reminder .claude/scripts/merge-local-permissions.py \
             .claude/scripts/merge-worktree-permissions.py .claude/statusline-command.sh; do
        grep -qF "$(basename "$f")" "${TESTHOME}/.claude/settings.json"
        [ -f "${TESTHOME}/${f}" ]
    done
}

@test "apply: local claude skills are deployed with frontmatter" {
    for s in my-voice optimize-prompt pr-screenshot codebase-memory; do
        [ -f "${TESTHOME}/.claude/skills/${s}/SKILL.md" ]
        grep -q "^name: ${s}$" "${TESTHOME}/.claude/skills/${s}/SKILL.md"
        grep -q '^description: ' "${TESTHOME}/.claude/skills/${s}/SKILL.md"
    done
    [ -x "${TESTHOME}/.claude/skills/pr-screenshot/scripts/capture-3widths.sh" ]
}

@test "apply: shared skill symlinks resolve into .agents/skills" {
    for s in agent-browser design-doc-mermaid grill-me humanizer-ja show-me; do
        [ -L "${TESTHOME}/.claude/skills/${s}" ]
        # symlink 先の SKILL.md まで到達できること
        [ -f "${TESTHOME}/.claude/skills/${s}/SKILL.md" ]
        [ -f "${TESTHOME}/.agents/skills/${s}/SKILL.md" ]
    done
    [ -f "${TESTHOME}/.agents/skills/find-skills/SKILL.md" ]
}

@test "apply: app configs are deployed" {
    [ -f "${TESTHOME}/.config/karabiner/karabiner.json" ]
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${TESTHOME}/.config/karabiner/karabiner.json"
    [ -f "${TESTHOME}/.config/wezterm/wezterm.lua" ]
    [ -f "${TESTHOME}/.config/zed/settings.json" ]
    [ -f "${TESTHOME}/.config/zed/AGENTS.md" ]
    [ -f "${TESTHOME}/.config/herdr/config.toml" ]
    [ -f "${TESTHOME}/.config/gh/config.yml" ]
    [ -f "${TESTHOME}/.config/git/ignore" ]
    [ -f "${TESTHOME}/.codex/config.toml" ]
    [ -f "${TESTHOME}/.codex/AGENTS.md" ]
    [ -f "${TESTHOME}/.gemini/settings.json" ]
    [ -f "${TESTHOME}/.cursor/skills-cursor/create-skill/SKILL.md" ]
}

@test "apply: codex config carries no machine-local trust state" {
    # [projects.*] / [hooks.state] は新マシンで無意味なので持ち込まないこと
    run grep -E '^\[(projects\.|hooks\.state)' "${TESTHOME}/.codex/config.toml"
    [ "$status" -ne 0 ]
}

@test "apply: zprofile and zshenv are deployed" {
    [ -f "${TESTHOME}/.zprofile" ]
    grep -q "brew shellenv" "${TESTHOME}/.zprofile"
    [ -f "${TESTHOME}/.zshenv" ]
}

@test "source tree contains no credentials" {
    # public リポジトリなのでトークン・秘密鍵が混入していないこと
    run grep -rIniE '(gho_|ghp_|ghu_|ghs_|github_pat_|npm_[A-Za-z0-9]{30}|sk-[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}|xox[baprs]-|-----BEGIN [A-Z ]*PRIVATE KEY|AIza[0-9A-Za-z_-]{30})' \
        "${REPO_ROOT}/home"
    [ "$status" -ne 0 ]
}
