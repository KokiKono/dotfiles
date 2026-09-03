# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal **macOS** dotfiles repository managed with [chezmoi](https://chezmoi.io). Config files
(zsh, git, VS Code) live under `home/` as a chezmoi source and are rendered into `$HOME` by
`chezmoi apply`. Machine setup (Homebrew, mise, oh-my-zsh, nodenv, VS Code extensions) is done by plain,
individually testable shell scripts under `install/`, exercised by [Bats](https://github.com/bats-core/bats-core)
and GitHub Actions CI. Modeled on https://zenn.dev/shunk031/articles/testable-dotfiles-management-with-chezmoi.

## Layout

```
.chezmoiroot                       # contains "home" — the chezmoi source dir
home/                              # chezmoi source (rendered into $HOME)
├── .chezmoi.yaml.tmpl             # prompts for name/email on init → chezmoi config data
├── dot_zshrc                      # → ~/.zshrc (thin loader: oh-my-zsh + sources dot_config/zsh/*.zsh)
├── dot_gitconfig.tmpl             # → ~/.gitconfig ({{ .name }}/{{ .email }} templated)
├── dot_gitignore_global           # → ~/.gitignore_global
├── dot_config/mise/config.toml    # → ~/.config/mise/config.toml (pinned node/python/java)
├── dot_config/zsh/{options,aliases,tools}.zsh # → ~/.config/zsh/... (split zshrc: shell opts / aliases / env+mise+wtp+gcloud)
├── dot_config/zsh/git-worktree.zsh # → ~/.config/zsh/... (wrm/brm/bd cleanup fns, sourced by dot_zshrc)
├── dot_claude/skills/my-voice/    # → ~/.claude/skills/my-voice/ (SKILL.md + references/{slack,formal,pr}-voice.md)
├── Library/Application Support/Code/User/{settings,keybindings}.json  # → VS Code user config
└── .chezmoiscripts/
    └── run_onchange_install.sh.tmpl   # on `apply`, runs install/macos/*.sh (re-runs when they change)
install/
├── common/lib.sh                  # shared helpers (REPO_ROOT, log, has)
└── macos/{brew,mise,ohmyzsh,nodenv,vscode}.sh
install/macos/vscode-extensions.txt # one extension ID per line (used by vscode.sh)
tests/
├── test_helper.bash               # finds REPO_ROOT via .chezmoiroot
├── install/macos/*.bats           # unit tests for each install script
└── files/apply.bats               # E2E: chezmoi apply into a throwaway HOME, assert output
.github/workflows/ci.yml           # macOS CI: bats + apply E2E (weekly full setup)
```

## chezmoi model

- `chezmoi apply` renders `home/` into `$HOME`. `dot_` → `.`, `*.tmpl` files are Go templates,
  `run_onchange_*` scripts execute when their rendered content changes.
- Editing a file here does **not** take effect until `chezmoi apply` (unlike the old symlink model).
- `home/.chezmoi.yaml.tmpl` uses `promptStringOnce` for `name`/`email`; those flow into `dot_gitconfig.tmpl`.
- `run_onchange_install.sh.tmpl` embeds a sha256 of each `install/**/*.sh` (via `glob`+`include`+`sha256sum`)
  so the install scripts re-run only when they change. It invokes them by
  `{{ .chezmoi.sourceDir }}/../install/macos/*.sh`.

## install/ script conventions

Every script is testable: `set -Eeuo pipefail`, logic in named functions + a `main`, and a source guard
so sourcing defines functions without running anything:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

Scripts are idempotent and skip gracefully when a prerequisite (brew/nodenv/code) is missing.

## Testing

- Run all tests: `bats -r tests/` (needs `brew install bats-core chezmoi`).
- `tests/files/apply.bats` applies into `$BATS_TEST_TMPDIR` with `--exclude scripts` (no brew side effects).
- Add a script → add `tests/install/macos/<name>.bats` alongside it.
- **`@test` titles must be ASCII** — bats mangles multibyte (Japanese) test names. Keep Japanese in comments only.

## Bootstrapping a new machine

```
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply KokiKono
```

`chezmoi apply` runs `run_onchange_install.sh` which chains `install/macos/{brew,mise,ohmyzsh,nodenv,vscode}.sh`
(Homebrew + `brew bundle` from `Brewfile`, `mise install`, oh-my-zsh, nodenv-yarn-install plugin, VS Code extensions).

## Key details when editing

- **`Brewfile`** is the source of truth for installed packages (~110 formulae/casks). Regenerate with
  `brew bundle dump --force`. `chezmoi` and `bats-core` are included.
- **`install/macos/vscode-extensions.txt`** is the extension list. Update with
  `code --list-extensions > install/macos/vscode-extensions.txt`.
- **Worktree/branch cleanup** lives in `home/dot_config/zsh/git-worktree.zsh` (sourced by `dot_zshrc`):
  `wrm` (remove worktrees whose PR is MERGED / has no PR, via `gh`; candidates are shown in an
  aligned STATE/BRANCH/PATH table in `fzf --multi`, **all pre-selected** (`start:select-all`), so
  Enter deletes the selection and Esc aborts; `-f`/`--force` passes `--force` to
  `git worktree remove`, `-a`/`--all` skips fzf and falls back to the y/N prompt over all
  candidates; PR states come from a single batched `gh pr list` per repo via the shared
  `__gwt_pr_states` helper — same one `wgs` uses — so `wrm` is one `gh` round-trip regardless of
  worktree count, and it aborts rather than treating everything as "no PR" if `gh` fails; during
  deletion it prints a `[n/N] ✔/✘ branch (path)` line per worktree — failures show the git error
  inline and do not stop the rest — followed by a `削除 x 件 / 失敗 y 件` summary; if anything
  failed and `-f` wasn't given, the failed worktrees are re-offered in a second fzf/prompt pass
  that retries them with `--force`. Returns non-zero if removals were still left failing/declined.
  The delete loop itself is `__gwt_remove_worktrees <force> <path\tbranch>...` (leaves failures in
  `__gwt_failed`) and the retry pass is `__gwt_retry_force`), `brm`
  (prune local branches merged
  to the default branch or whose upstream is `[gone]`), `bd` (fzf-pick branch delete with MERGED/UNMERGED
  preview), `wgs` (**read-only** cross-repo search: scans all git repos under a root — default `~/git_clone`,
  args override — and lists worktrees matching `wrm`'s condition; fast via early-skip of repos without extra
  worktrees + one batched `gh pr list` per repo + parallel scan; tune with `WGS_MAX`/`WGS_LIMIT`; cleanup is
  still per-repo `wrm`). All need `fzf` (except `wgs`); `wrm`/`wgs` need `gh`. Worktree **create/switch**
  stays with `wtp`. The default branch is auto-detected (`origin/HEAD` → main/master), so these work across repos.
- **`dot_zshrc` is a thin loader.** It bootstraps oh-my-zsh, then sources `~/.config/zsh/{options,aliases,tools}.zsh`
  (in that order — `options.zsh` runs `compinit` before `tools.zsh`'s `compdef`), then `~/.pzshrc`, then
  `git-worktree.zsh`. `options.zsh`=shell opts/history/keybinds, `aliases.zsh`=aliases,
  `tools.zsh`=env/PATH + mise + wtp + gcloud. **The Rancher Desktop managed block and the `~/.pzshrc`
  source stay inline in `dot_zshrc`** (Rancher rewrites its block in `~/.zshrc` directly — keep it there
  to avoid re-injection/drift). Add new shell config to the matching module, not to `dot_zshrc`.
- The zshrc assumes `robbyrussell` oh-my-zsh theme, **`mise`** (single `eval "$(mise activate zsh)"`),
  bun, Rancher Desktop, and gcloud. It sources `~/.pzshrc` for machine-private secrets.
- **gcloud** is the Homebrew cask `gcloud-cli` (in `Brewfile`). `tools.zsh` sources
  `/opt/homebrew/share/google-cloud-sdk/{path,completion}.zsh.inc`. Update it with `gcloud components
  update` (the cask supports the native component manager). Auth/config lives in `~/.config/gcloud`
  independent of the SDK. (Old manual install under `~/googlecloud/google-cloud-sdk` is superseded.)
- **Version managers are consolidated to `mise`.** Pinned tools live in `home/dot_config/mise/config.toml`
  → `~/.config/mise/config.toml` (`node`/`python`/`java`); go uses Homebrew, ruby uses macOS system.
  `ES_JAVA_HOME` is derived from mise's `$JAVA_HOME`. The old `anyenv`/`nodenv`/`goenv`/`pyenv`/`rbenv`/`jenv`
  init lines and dead Intel-Homebrew (`/usr/local/opt/...`) / Volta paths were removed; those managers
  remain installed on disk (Brewfile) but are no longer initialized, so the switch is reversible.
- **`home/dot_claude/skills/my-voice/`** is the only `~/.claude` content under chezmoi (other local
  skills — `optimize-prompt`, `pr-screenshot` — remain untracked). It teaches Claude to write in the
  author's voice, with one reference per medium: `slack-voice.md` (です/ます + 「！」+ 文末絵文字),
  `formal-voice.md` (Notion 社内文書、常体・数字と表・「今回は着手しないもの」),
  `pr-voice.md` (PR 本文、レビュワー確認ポイントを重い順に). The references are **distilled from real
  Slack / Notion / GitHub content, and this repo is PUBLIC** — every proper noun, URL and concrete
  number must be anonymized to `○○` / `△△` / `（リンク）` before it lands here. Edits don't reach
  `~/.claude/skills/my-voice/` until `chezmoi apply`. `tests/files/apply.bats` guards both the
  deployment and the anonymization.

## Secrets

Machine-private secrets belong in `~/.pzshrc` (sourced at the end of `.zshrc`), never in tracked files.
If any secret is found in a tracked file, flag it rather than committing over it.

Historical note: a `GREN_GITHUB_TOKEN` was previously hardcoded in the zshrc. It has been removed from
the working tree but still exists in git history and must be revoked at https://github.com/settings/tokens.

## Migration status (symlink → chezmoi)

Migration is complete. The old per-tool `install.sh` scripts, `setup.sh`, and the entire `.config/`
directory (the old symlink-model source) have been removed. On the primary machine chezmoi is already
activated: `~/.local/share/chezmoi` is a symlink to this repo, `~/.config/chezmoi/chezmoi.yaml` holds the
`name`/`email` data, and `~/.zshrc` / `~/.gitconfig` / `~/.gitignore_global` are now chezmoi-managed
regular files (no longer symlinks).

Note: the initial activation used `chezmoi apply --exclude scripts`, so `run_onchange_install.sh` has not
run yet. The next plain `chezmoi apply` will run it once (Homebrew + `brew bundle`, oh-my-zsh, etc.). Use
`--exclude scripts` if you only want to sync files.
