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
    # 署名鍵はマシン固有なので include に逃がしてあること（この repo は PUBLIC）
    grep -q "config/git/signing.conf" "${TESTHOME}/.gitconfig"
    run grep -qE "^[[:space:]]*signingKey" "${TESTHOME}/.gitconfig"
    [ "$status" -ne 0 ]
    run grep -q "C84E50F83C8B8E39" "${TESTHOME}/.gitconfig"
    [ "$status" -ne 0 ]
    # no unrendered template syntax left
    run grep -F '{{' "${TESTHOME}/.gitconfig"
    [ "$status" -ne 0 ]
}

@test "apply: gitconfig wires up delta as the pager" {
    # delta (brew git-delta) をページャに使う。tty のときだけ効くので非対話実行には影響しない
    grep -qE "^[[:space:]]*pager = delta$" "${TESTHOME}/.gitconfig"
    grep -qE "^[[:space:]]*diffFilter = delta --color-only$" "${TESTHOME}/.gitconfig"
    grep -qE "^[[:space:]]*conflictStyle = zdiff3$" "${TESTHOME}/.gitconfig"
    # git が設定として読めること（セクション名の綴り間違いを拾う）
    run git config --file "${TESTHOME}/.gitconfig" --get core.pager
    [ "$status" -eq 0 ]
    [ "$output" = "delta" ]
    run git config --file "${TESTHOME}/.gitconfig" --get interactive.diffFilter
    [ "$status" -eq 0 ]
    [ "$output" = "delta --color-only" ]
    # Brewfile に git-delta があること（無いと新マシンでページャが起動しない）
    grep -qE '^brew "git-delta"' "${REPO_ROOT}/Brewfile"
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
    [ -f "${TESTHOME}/.config/zsh/hello-run.zsh" ]
    [ -f "${TESTHOME}/.config/zsh/dev-server.zsh" ]
    # herdr のタブ探索は hello-run と dev-server の共通部分。両方がこれを source する
    [ -f "${TESTHOME}/.config/zsh/herdr-lib.zsh" ]
}

@test "apply: zshrc is a thin loader sourcing the modules" {
    grep -q 'source $ZSH/oh-my-zsh.sh' "${TESTHOME}/.zshrc"
    grep -q 'ZSH_CONF_DIR' "${TESTHOME}/.zshrc"
    grep -q 'git-worktree.zsh' "${TESTHOME}/.zshrc"
    grep -q 'hello-run.zsh' "${TESTHOME}/.zshrc"
    grep -q 'dev-server.zsh' "${TESTHOME}/.zshrc"
}

@test "apply: hello-run has no hardcoded org or repo names" {
    # public リポジトリなので勤務先の org/repo 名は既定値に持たず ~/.pzshrc から読むこと。
    # 名前そのものをここに書くと本末転倒なので「既定値が空であること」を検査する。
    HR="${TESTHOME}/.config/zsh/hello-run.zsh"
    grep -q 'HELLO_RUN_ROOT="${HELLO_RUN_ROOT:-}"' "${HR}"
    grep -q 'HELLO_RUN_ISSUE_REPO="${HELLO_RUN_ISSUE_REPO:-}"' "${HR}"
    # HELLO_RUN_REPOS は typeset のみで、既定のリポジトリ名を代入していないこと
    run grep -E '^HELLO_RUN_REPOS=\(' "${HR}"
    [ "$status" -ne 0 ]
    grep -q 'pzshrc' "${HR}"
}

@test "apply: hello-run prompt template is deployed with placeholders only" {
    TPL="${TESTHOME}/.config/hello-run/prompt.md"
    [ -f "${TPL}" ]
    # 差し込みが効くこと（本文を直接書くと ~/.pzshrc の設定が反映されない）
    grep -qF '{{issue_url}}' "${TPL}"
    grep -qF '{{repos}}' "${TPL}"
    grep -qF '{{branch}}' "${TPL}"
    # public リポジトリなので勤務先の org/repo 名をテンプレートに置かないこと
    run grep -nE 'HELLO_RUN_REPOS=\(|github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues' "${TPL}"
    [ "$status" -ne 0 ]
    # hello-run 側がこのファイルを既定の置き場として見ていること
    grep -q 'HELLO_RUN_PROMPT_FILE' "${TESTHOME}/.config/zsh/hello-run.zsh"
    grep -q 'config/hello-run/prompt.md' "${TESTHOME}/.config/zsh/hello-run.zsh"
}

@test "apply: hello-run scratch prompt template is deployed with placeholders only" {
    # issue を起票していない作業用。issue 版と共用すると、どちらでも意味が通る
    # 曖昧な文面に寄るので置き場ごと分けてある
    TPL="${TESTHOME}/.config/hello-run/prompt-scratch.md"
    [ -f "${TPL}" ]
    grep -qF '{{repos}}' "${TPL}"
    grep -qF '{{branch}}' "${TPL}"
    # public リポジトリなので勤務先の org/repo 名をテンプレートに置かないこと
    run grep -nE 'HELLO_RUN_REPOS=\(|github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "${TPL}"
    [ "$status" -ne 0 ]
    # hello-run 側がこのファイルを既定の置き場として見ていること
    grep -q 'HELLO_RUN_SCRATCH_PROMPT_FILE' "${TESTHOME}/.config/zsh/hello-run.zsh"
    grep -q 'config/hello-run/prompt-scratch.md' "${TESTHOME}/.config/zsh/hello-run.zsh"
}

@test "apply: hello-run creates worktrees from the fetched default branch" {
    # wt は fetch せず base もローカルのデフォルトブランチなので、古い base から
    # 枝が生えないよう fetch と --base origin/<default> が入っていること
    grep -q 'fetch --prune origin' "${TESTHOME}/.config/zsh/hello-run.zsh"
    grep -q -- '--base "origin/\$base"' "${TESTHOME}/.config/zsh/hello-run.zsh"
}

@test "apply: hello-run herdr plugin is deployed and runnable" {
    PLUGIN="${TESTHOME}/.config/herdr/plugins/hello-run"
    [ -f "${PLUGIN}/herdr-plugin.toml" ]
    [ -x "${PLUGIN}/pick.zsh" ]
    # pick.zsh は fzf の reload バインドから issues.zsh を叩くので、両方揃って動く
    [ -x "${PLUGIN}/issues.zsh" ]
    run zsh -n "${PLUGIN}/pick.zsh"
    [ "$status" -eq 0 ]
    run zsh -n "${PLUGIN}/issues.zsh"
    [ "$status" -eq 0 ]
    # マニフェストが起動するスクリプトが実在すること（argv の末尾がパス）
    run python3 -c "
import sys, tomllib
m = tomllib.load(open(sys.argv[1], 'rb'))
pane = m['panes'][0]
print(m['id'], pane['command'][-1])
" "${PLUGIN}/herdr-plugin.toml"
    [ "$status" -eq 0 ]
    [ -f "${PLUGIN}/$(echo "$output" | cut -d' ' -f2)" ]
}

@test "apply: herdr keybinding points at the hello-run plugin that ships here" {
    # config.toml のキーバインドとマニフェストの id / entrypoint がずれていないこと
    run python3 -c "
import sys, tomllib
m = tomllib.load(open(sys.argv[1], 'rb'))
cfg = tomllib.load(open(sys.argv[2], 'rb'))
want_ids = {m['id']}
pane_ids = {p['id'] for p in m['panes']}
cmds = [k.get('command', '') for k in cfg.get('keys', {}).get('command', [])]
hit = [c for c in cmds if m['id'] in c]
assert hit, f'no keybinding invokes {m[\"id\"]}: {cmds}'
for c in hit:
    ep = c.split('--entrypoint', 1)[1].split()[0]
    assert ep in pane_ids, f'unknown entrypoint {ep} (have {pane_ids})'
" "${TESTHOME}/.config/herdr/plugins/hello-run/herdr-plugin.toml" \
  "${TESTHOME}/.config/herdr/config.toml"
    [ "$status" -eq 0 ]
}

@test "apply: git-diff herdr plugin is deployed and runnable" {
    PLUGIN="${TESTHOME}/.config/herdr/plugins/git-diff"
    [ -f "${PLUGIN}/herdr-plugin.toml" ]
    [ -x "${PLUGIN}/pick.zsh" ]
    # pick.zsh は一覧を files.zsh、preview を show.zsh に任せるので 3 つ揃って動く
    [ -x "${PLUGIN}/files.zsh" ]
    [ -x "${PLUGIN}/show.zsh" ]
    [ -f "${PLUGIN}/lib.zsh" ]
    for f in pick files show lib; do
        run zsh -n "${PLUGIN}/${f}.zsh"
        [ "$status" -eq 0 ]
    done
    # マニフェストが起動するスクリプトが実在すること（argv の末尾がパス）
    run python3 -c "
import sys, tomllib
m = tomllib.load(open(sys.argv[1], 'rb'))
print(m['panes'][0]['command'][-1])
" "${PLUGIN}/herdr-plugin.toml"
    [ "$status" -eq 0 ]
    [ -f "${PLUGIN}/${output}" ]
}

@test "apply: herdr keybindings match the plugins that ship here" {
    # config.toml のキーバインドが、配られたマニフェストの id / entrypoint と
    # ずれていないこと（プラグインを足すたびに両方直す必要がある）
    run python3 -c "
import glob, os, sys, tomllib
cfg = tomllib.load(open(sys.argv[1], 'rb'))
cmds = [k.get('command', '') for k in cfg.get('keys', {}).get('command', [])]
for manifest in glob.glob(os.path.join(sys.argv[2], '*', 'herdr-plugin.toml')):
    m = tomllib.load(open(manifest, 'rb'))
    pane_ids = {p['id'] for p in m['panes']}
    hit = [c for c in cmds if m['id'] in c]
    assert hit, f'no keybinding invokes {m[\"id\"]}: {cmds}'
    for c in hit:
        ep = c.split('--entrypoint', 1)[1].split()[0]
        assert ep in pane_ids, f'unknown entrypoint {ep} (have {pane_ids})'
" "${TESTHOME}/.config/herdr/config.toml" "${TESTHOME}/.config/herdr/plugins"
    [ "$status" -eq 0 ]
}

@test "apply: install/macos/herdr.sh links every plugin that ships here" {
    # link 漏れがあるとキーを押しても何も開かない
    for d in "${REPO_ROOT}"/home/dot_config/herdr/plugins/*/; do
        name="$(basename "${d}")"
        grep -q "\"${name}\"" "${REPO_ROOT}/install/macos/herdr.sh"
    done
}

@test "apply: hello-run plugin has no hardcoded org or repo names" {
    # hello-run 本体と同じ理由（public リポジトリ）。対象は ~/.pzshrc から読むこと
    PLUGIN="${TESTHOME}/.config/herdr/plugins/hello-run"
    grep -q 'pzshrc' "${PLUGIN}/pick.zsh"
    run grep -E 'HELLO_RUN_(ROOT|ISSUE_REPO|ISSUE_ORG|REPOS)=[^"$]' "${PLUGIN}/pick.zsh" "${PLUGIN}/issues.zsh"
    [ "$status" -ne 0 ]
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

@test "apply: claude global instructions are deployed" {
    # CLAUDE.md は AGENTS.md を読み込むだけの薄いファイル（実体は AGENTS.md 側）
    [ -f "${TESTHOME}/.claude/CLAUDE.md" ]
    grep -qF '@AGENTS.md' "${TESTHOME}/.claude/CLAUDE.md"
    [ -f "${TESTHOME}/.claude/AGENTS.md" ]
    [ -s "${TESTHOME}/.claude/AGENTS.md" ]
    # PUBLIC リポジトリなので社名・private な URL が漏れていないこと
    run grep -rniE 'gritinc|progrit|slack\.com/archives|app\.notion\.com|notion\.so|docs\.google\.com|drive\.google\.com' \
        "${TESTHOME}/.claude/CLAUDE.md" "${TESTHOME}/.claude/AGENTS.md"
    [ "$status" -ne 0 ]
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
    for s in my-voice optimize-prompt pr-screenshot github-attach codebase-memory \
             learning-code ubiquitous-language dev-server; do
        [ -f "${TESTHOME}/.claude/skills/${s}/SKILL.md" ]
        grep -q "^name: ${s}$" "${TESTHOME}/.claude/skills/${s}/SKILL.md"
        grep -q '^description: ' "${TESTHOME}/.claude/skills/${s}/SKILL.md"
    done
    [ -x "${TESTHOME}/.claude/skills/pr-screenshot/scripts/capture-3widths.sh" ]
}

@test "apply: dev-server ships no repo-specific app table" {
    SKILL="${TESTHOME}/.claude/skills/dev-server"
    # リポジトリ固有の表（アプリ名・内部 URL・ポート）は public なここに置かない。
    # 表の中身そのものを書くと本末転倒なので、配られないことを検査する
    [ ! -d "${SKILL}/references" ]
    # 表の置き場（非追跡）と、置くべきキーは SKILL.md 側に残っていること
    grep -q 'config/dev-server' "${SKILL}/SKILL.md"
    grep -q '{{port}}' "${SKILL}/SKILL.md"
    # herdr 前提のスキルなので、外で動かせないことを明示していること
    grep -q 'HERDR_ENV' "${SKILL}/SKILL.md"
    # 手順書ではなく CLI 呼び出しに委ねていること
    grep -q 'dev-server --json' "${SKILL}/SKILL.md"
}

@test "apply: dev-server config example ships placeholders only" {
    EXAMPLE="${TESTHOME}/.config/dev-server/apps.example.json"
    [ -f "${EXAMPLE}" ]
    jq -e . "${EXAMPLE}" >/dev/null
    # 雛形なので {{port}} の使い方が分かること
    grep -qF '{{port}}' "${EXAMPLE}"
    # 実データ（アプリ名・実ポート）は非追跡の <repo>.json 側。雛形に漏らさない
    run jq -r '.apps[].name' "${EXAMPLE}"
    [ "$status" -eq 0 ]
    for n in ${lines[@]}; do
        [[ "$n" == "○○" || "$n" == "△△" ]] || false
    done
    run grep -nE '"base_port": (4000|8000|9000|3003|3004|3005|3040|6006|6007)' "${EXAMPLE}"
    [ "$status" -ne 0 ]
}

@test "apply: learning-code skill is deployed with references and script" {
    SKILL="${TESTHOME}/.claude/skills/learning-code"
    for f in references/levels.md references/quiz.md references/schema.md \
             references/cob.md references/skills.template.json; do
        [ -f "${SKILL}/${f}" ]
    done
    [ -x "${SKILL}/scripts/skills-db.sh" ]
    # 雛形は空の状態で配られること（個人の学習データは ~/.learning 側にしか置かない）
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['domains'] == {}" \
        "${SKILL}/references/skills.template.json"
}

@test "apply: ubiquitous-language skill is deployed with its references" {
    SKILL="${TESTHOME}/.claude/skills/ubiquitous-language"
    [ -f "${SKILL}/SKILL.md" ]
    [ -f "${SKILL}/references/schema.md" ]
    [ -f "${SKILL}/references/judgment.md" ]
    grep -q '^name: ubiquitous-language$' "${SKILL}/SKILL.md"
    grep -q '^description: ' "${SKILL}/SKILL.md"
    # 追記先の設定は追跡外。chezmoi が配ってしまっていないこと
    [ ! -e "${TESTHOME}/.claude/ubiquitous-language.local.json" ]
}

@test "apply: ubiquitous-language skill leaks no workspace identifiers" {
    # public リポジトリなので、社内の固有名詞・Notion の ID/URL が混入していないこと
    run grep -rniE 'gritinc|progrit|slack\.com/archives|app\.notion\.com|notion\.so|[0-9a-f]{32}' \
        "${TESTHOME}/.claude/skills/ubiquitous-language"
    [ "$status" -ne 0 ]
}

@test "apply: external skills are left to skills-lock.json, not deployed" {
    # 外部スキルは install/macos/skills.sh が `npx skills add` で入れるので
    # chezmoi は本体も symlink も配置しないこと
    [ ! -e "${TESTHOME}/.agents/skills" ]
    for s in agent-browser design-doc-mermaid grill-me humanizer-ja show-me herdr; do
        [ ! -e "${TESTHOME}/.claude/skills/${s}" ]
    done
}

@test "apply: ghostty config is deployed and pins the window" {
    CFG="${TESTHOME}/.config/ghostty/config"
    [ -f "${CFG}" ]
    # WM を入れない方針なので、位置とサイズは端末自身が持つ。どれか欠けると毎回置き直しになる。
    grep -q '^window-position-x = 0$' "${CFG}"
    grep -q '^window-position-y = 0$' "${CFG}"
    grep -qE '^window-width = [0-9]+$' "${CFG}"
    grep -qE '^window-height = [0-9]+$' "${CFG}"
    # 保存状態を復元されると上の指定が無視される
    grep -q '^window-save-state = never$' "${CFG}"
    # herdr の prefix/alt 系が死ぬので option は alt として通すこと
    grep -q '^macos-option-as-alt = true$' "${CFG}"
}

@test "apply: ghostty config declares a font that the Brewfile installs" {
    FAMILY="$(grep '^font-family = ' "${TESTHOME}/.config/ghostty/config" | cut -d'"' -f2)"
    [ -n "${FAMILY}" ]
    # JetBrainsMono Nerd Font -> font-jetbrains-mono-nerd-font
    SLUG="font-$(echo "${FAMILY}" | tr 'A-Z' 'a-z' | tr -d ' ' \
        | command sed -E 's/mono/-mono-/; s/nerdfont/nerd-font/')"
    grep -q "cask \"${SLUG}\"" "${REPO_ROOT}/Brewfile"
}

@test "apply: helix config is deployed as valid toml" {
    CFG="${TESTHOME}/.config/helix/config.toml"
    [ -f "${CFG}" ]
    python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "${CFG}"
    # 隠しディレクトリ（.github/ .claude/）がピッカーに出ないと、このリポジトリでは使い物にならない
    python3 -c "
import tomllib, sys
cfg = tomllib.load(open(sys.argv[1], 'rb'))
assert cfg['editor']['file-picker']['hidden'] is False, cfg['editor']['file-picker']
" "${CFG}"
}

@test "apply: EDITOR points at helix everywhere it is defaulted" {
    grep -q '^export EDITOR=hx$' "${TESTHOME}/.config/zsh/options.zsh"
    # プラグインは zsh -l で起動し ~/.zshrc を読まないので、自前の既定を持っている。
    # ここが vim のままだと、ピッカーの p だけ別のエディタが開く。
    grep -q 'EDITOR:-hx' "${TESTHOME}/.config/herdr/plugins/hello-run/pick.zsh"
}

@test "apply: herdr binds an editor and a lazygit command" {
    run python3 -c "
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], 'rb'))
cmds = {k['key']: k for k in cfg['keys']['command']}

ed = cmds['prefix+shift+e']
# type = 'pane' は終了で閉じる一時ズームペイン。shell にすると detach して何も出ない。
assert ed['type'] == 'pane', ed
assert ed['command'].startswith('hx'), ed

lg = cmds['prefix+shift+g']
assert lg['type'] == 'popup', lg
assert lg['command'] == 'lazygit', lg
" "${TESTHOME}/.config/herdr/config.toml"
    [ "$status" -eq 0 ]
}

@test "apply: hello-run prompt asks claude to pull the spec from Notion" {
    # GitHub <-> Notion の往復を減らすのが目的。ここが消えると手で開きに行く運用に戻る。
    grep -q 'Notion' "${TESTHOME}/.config/hello-run/prompt.md"
}

@test "apply: kb autosave script and its launchd agent are deployed" {
    [ -x "${TESTHOME}/.config/kb/autosave.sh" ]
    PLIST="${TESTHOME}/Library/LaunchAgents/com.kokikono.kb-autosave.plist"
    [ -f "${PLIST}" ]
    if command -v plutil >/dev/null 2>&1; then plutil -lint "${PLIST}" >/dev/null; fi
    grep -q '<integer>600</integer>' "${PLIST}"
    grep -q '/.config/kb/autosave.sh</string>' "${PLIST}"
}

@test "apply: hello-run kb templates are deployed" {
    grep -q '{{issue_url}}' "${TESTHOME}/.config/hello-run/kb-readme.md"
    grep -q '{{kb_readme}}' "${TESTHOME}/.config/hello-run/prompt-kb.md"
    grep -q 'config/hello-run/kb-readme.md' "${TESTHOME}/.config/zsh/hello-run.zsh"
    grep -q 'config/hello-run/prompt-kb.md' "${TESTHOME}/.config/zsh/hello-run.zsh"
}

@test "apply: gh extensions have a restore path" {
    [ -f "${REPO_ROOT}/install/macos/gh-extensions.txt" ]
    # チェーンに繋がっていないと chezmoi apply で走らない
    grep -q 'macos/gh.sh' "${REPO_ROOT}/home/.chezmoiscripts/run_onchange_install.sh.tmpl"
}

@test "apply: attachment skills upload via gh's built-in --attach" {
    # 放っておくと GitHub Releases に画像を上げて本文からリンクする。標準の --attach に揃える
    for s in github-attach pr-screenshot; do
        grep -q -- '--attach' "${TESTHOME}/.claude/skills/${s}/SKILL.md"
        run grep -qE '^ *gh attach |--url-only|playwright-cli' "${TESTHOME}/.claude/skills/${s}/SKILL.md"
        [ "$status" -ne 0 ]
    done
    # <img src> は --attach が置換しないので、表の画像は Markdown 記法で書く
    run grep -qE '\| <img ' "${TESTHOME}/.claude/skills/pr-screenshot/SKILL.md"
    [ "$status" -ne 0 ]
    [ ! -e "${TESTHOME}/.claude/skills/pr-screenshot/scripts/ensure-gh-attach-patch.sh" ]
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
