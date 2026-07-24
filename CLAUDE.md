# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A personal **macOS** dotfiles repository managed with [chezmoi](https://chezmoi.io). Config files
(zsh, git, VS Code) live under `home/` as a chezmoi source and are rendered into `$HOME` by
`chezmoi apply`. Machine setup (Homebrew, oh-my-zsh, nodenv, VS Code extensions) is done by plain,
individually testable shell scripts under `install/`, exercised by [Bats](https://github.com/bats-core/bats-core)
and GitHub Actions CI. Modeled on https://zenn.dev/shunk031/articles/testable-dotfiles-management-with-chezmoi.

## Layout

```
.chezmoiroot                       # contains "home" — the chezmoi source dir
home/                              # chezmoi source (rendered into $HOME)
├── .chezmoi.yaml.tmpl             # prompts for name/email on init → chezmoi config data
├── dot_zshrc                      # → ~/.zshrc
├── dot_gitconfig.tmpl             # → ~/.gitconfig ({{ .name }}/{{ .email }} templated)
├── dot_gitignore_global           # → ~/.gitignore_global
├── Library/Application Support/Code/User/{settings,keybindings}.json  # → VS Code user config
└── .chezmoiscripts/
    └── run_onchange_install.sh.tmpl   # on `apply`, runs install/macos/*.sh (re-runs when they change)
install/
├── common/lib.sh                  # shared helpers (REPO_ROOT, log, has)
└── macos/{brew,ohmyzsh,nodenv,vscode}.sh
install/macos/vscode-extensions.txt # one extension ID per line (used by vscode.sh)
tests/
├── test_helper.bash               # finds REPO_ROOT via .chezmoiroot
├── install/macos/*.bats           # unit tests for each install script
└── files/apply.bats               # E2E: chezmoi apply into a throwaway HOME, assert output
.github/workflows/ci.yml           # macOS CI: bats + apply E2E + best-effort kcov/Codecov
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

`chezmoi apply` runs `run_onchange_install.sh` which chains `install/macos/{brew,ohmyzsh,nodenv,vscode}.sh`
(Homebrew + `brew bundle` from `Brewfile`, oh-my-zsh, nodenv-yarn-install plugin, VS Code extensions).

## Key details when editing

- **`Brewfile`** is the source of truth for installed packages (~110 formulae/casks). Regenerate with
  `brew bundle dump --force`. `chezmoi`, `bats-core`, `kcov` are included.
- **`install/macos/vscode-extensions.txt`** is the extension list. Update with
  `code --list-extensions > install/macos/vscode-extensions.txt`.
- The zshrc assumes `robbyrussell` oh-my-zsh theme, `anyenv` (nodenv/goenv/pyenv/rbenv/jenv), bun,
  Rancher Desktop, and gcloud. It sources `~/.pzshrc` at the end for machine-private secrets.
- `dot_zshrc` is currently carried over verbatim from the old config; it still contains duplicate
  version-manager init lines. A future cleanup (dedup / consolidate to `mise`) is a separate task.

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
