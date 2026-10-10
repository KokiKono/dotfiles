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
├── dot_claude/                    # → ~/.claude/ (CLAUDE.md→AGENTS.md, settings.json, .mcp.json, statusline, hooks/, scripts/, skills/)
├── dot_codex/, dot_gemini/, private_dot_cursor/  # → 他エージェント CLI の設定
├── dot_config/{karabiner,wezterm,zed,herdr,private_gh,git}/  # → 各アプリ設定（herdr は config.toml + 自作 plugin）
├── dot_zprofile, dot_zshenv       # → ~/.zprofile (brew shellenv + OrbStack), ~/.zshenv (cargo env)
├── Library/Application Support/Code/User/{settings,keybindings}.json  # → VS Code user config
└── .chezmoiscripts/
    └── run_onchange_install.sh.tmpl   # on `apply`, runs install/macos/*.sh (re-runs when they change)
install/
├── common/lib.sh                  # shared helpers (REPO_ROOT, log, has)
└── macos/{brew,gpg,mise,ohmyzsh,nodenv,vscode,skills,herdr}.sh
install/macos/vscode-extensions.txt # one extension ID per line (used by vscode.sh)
install/macos/skills-lock.json      # `npx skills` の lock のコピー（skills.sh が復元に使う）
tests/
├── test_helper.bash               # finds REPO_ROOT via .chezmoiroot
├── install/macos/*.bats           # unit tests for each install script
├── claude/skills-db.bats          # unit tests for the learning-code skill's skills-db.sh
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
- **Assertions must not be a bare `[[ ... ]]` in the middle of a test.** macOS の bash では
  errexit が `[[ ]]` の失敗で止まらないので、行末以外の `[[ ]]` は失敗しても ok になる
  （`[ ... ]` は止まる）。`|| false` を付けること。これを知らずに書いた assertion が
  90 箇所近くあり、付けて初めて 1 件が本当に落ちた。
- **`@test` titles must be ASCII** — bats mangles multibyte (Japanese) test names. Keep Japanese in comments only.

## Bootstrapping a new machine

```
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply KokiKono
```

`chezmoi apply` runs `run_onchange_install.sh` which chains `install/macos/{brew,gpg,mise,ohmyzsh,nodenv,vscode,skills,herdr}.sh`
(Homebrew + `brew bundle` from `Brewfile`, `mise install`, oh-my-zsh, nodenv-yarn-install plugin, VS Code extensions).

## Key details when editing

- **`Brewfile`** is the source of truth for installed packages: 18 `tap`, 156 `brew`, 34 `cask`,
  9 `mas` (Mac App Store — needs `brew "mas"`, which is in the file), 5 `npm`, 3 `go`, 54 `vscode`.
  `chezmoi` and `bats-core` are included. Regenerate with:

  ```
  grep -E '^vscode ' Brewfile > /tmp/vscode-block.txt      # ← 先に退避
  brew bundle dump --force --no-vscode
  grep -v '^#' Brewfile | cat -s > /tmp/bf && mv /tmp/bf Brewfile   # describe コメントを落とす
  printf '\n' >> Brewfile && cat /tmp/vscode-block.txt >> Brewfile
  ```

  **`--no-vscode` を必ず付けること。** `brew bundle dump` は `code --list-extensions` の結果で
  `vscode` 行を上書きするので、拡張が入っていない環境（プロファイルが空、`code` CLI が無い等）で
  素朴に dump すると 54 行の拡張リストが消える。同じ理由で `install/macos/vscode-extensions.txt`
  も `code --list-extensions` が空でないことを確認してから更新する
  (`code --list-extensions > install/macos/vscode-extensions.txt`)。
- **GPG 署名は `install/macos/gpg.sh` がマシン側を用意する。** `dot_gitconfig.tmpl` は
  `commit.gpgsign = true` と `[gpg] program = gpg` を持つが、**鍵 ID は持たない** — マシン固有なので
  `[include] path = ~/.config/git/signing.conf` に逃がしてあり、そのファイルは `gpg.sh` が書き出す
  （非追跡。git は存在しない include を黙って無視する）。`gpg.sh` は brew の直後に走り、
  ① `~/.gnupg` を 700 で作り ② `gpg-agent.conf` に `pinentry-program $(command -v pinentry-mac)` と
  キャッシュ TTL を書き ③ `git config user.email` に一致する秘密鍵の fingerprint を `signing.conf` に
  書く。④ 鍵が無ければ `gpg --quick-generate-key ... ed25519 sign never` で作り公開鍵を表示するが、
  **パスフレーズ入力が要るので `[[ -t 0 ]]` かつ `$CI` が空のときだけ** — CI の `e2e-full` や
  `chezmoi apply` 経由では生成せずスキップするので、新マシンでは一度ターミナルから
  `bash install/macos/gpg.sh` を叩くこと。`gnupg` / `pinentry-mac` は Brewfile 済み。
  テストは `gpg`/`pinentry-mac`/`gpgconf`/`git` を PATH にスタブし、`GNUPGHOME` と
  `GIT_SIGNING_CONF` を tmpdir に向けて検証する。
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
- **`hello-run`** (`home/dot_config/zsh/hello-run.zsh`, sourced by `dot_zshrc` after `git-worktree.zsh`)
  builds a whole work environment from a GitHub issue: it resolves the issue, has haiku guess a slug,
  creates one worktree per repo under `<root>/.sessions/issue-<N>/`, lays out a herdr tab with a pane
  per repo, and launches `claude` in the main pane. Needs `herdr` (`HERDR_ENV=1`), `wt`, `gh`, `jq`.
  Two things to know when editing:
  - **The target org/repos are NOT in this repo** — it is PUBLIC. `HELLO_RUN_ROOT` /
    `HELLO_RUN_ISSUE_REPO` / `HELLO_RUN_REPOS` default to empty and the real values live in
    `~/.pzshrc` (untracked; `dot_zshrc` sources it *before* `hello-run.zsh`, so the `${VAR:-}`
    defaults pick them up). `hello-run` errors out with a pointer to `~/.pzshrc` if they are unset,
    and `apply.bats` asserts no org/repo name leaks into the deployed file.
  - **既存タブの探索は全 workspace。** タブはそれを作ったときに居た workspace に残るので、
    別の workspace から `hello-run` を叩くと現在の workspace には無い。`__hr_find_tab` が
    `herdr workspace list` を回して `<ws>\t<tab>` を返し、別 workspace なら
    `herdr workspace focus` を挟んでから `tab focus` する（`tab focus` だけでは移れない）。
    これを現在の workspace 固定に戻すと、既にあるのに同じラベルのタブをもう 1 つ作る。
  - **プラグインの pane には `HERDR_WORKSPACE_ID` が渡ってこない。** herdr が渡すのは
    `HERDR_PLUGIN_CONTEXT_JSON`（`workspace_id` / `tab_id` / `focused_pane_id` /
    `focused_pane_cwd` などが入っている）だけなので、環境変数をそのまま
    `herdr tab create --workspace` に渡すと popup 経由のときだけ
    `workspace_not_found` で落ちる。`__hr_workspace_id` が
    環境変数 → context JSON → `workspace list` の `focused` の順に引き直す。
  - **`wt` never fetches, and its `--base` default is the *local* default branch**, so a naive
    `wt switch --create` branches off whenever the parent repo was last pulled. `__hr_make_worktree`
    therefore runs `git fetch --prune origin` and passes `--base origin/<default>` (detected by
    `__hr_default_branch` via `origin/HEAD` → main/master). Base and branch names differ, so the new
    branch gets no upstream — same as before; push with `-u` or `push.autoSetupRemote`.
- **`home/dot_config/herdr/plugins/hello-run/`** は自作の herdr プラグイン
  (`kokikono.hello-run`)。`prefix+Shift+H` でどのペインからでも popup が開き、`gh` で取った
  issue を `fzf` で選ぶと `hello-run <url>` が走る。中身は `herdr-plugin.toml`（起動方法の宣言）、
  `pick.zsh`（実装）、`issues.zsh`（issue 一覧を TSV で吐く）。知っておくこと:
  - **一覧は org 横断で、自分にアサインされた open issue だけ。** リポジトリ単位の
    `gh issue list` ではなく `gh search issues --owner <org> --assignee @me` を使う。org 名は
    持たず、`~/.pzshrc` の `HELLO_RUN_ISSUE_REPO`（`<org>/<repo>`）の所有者部分から取る
    （`HELLO_RUN_ISSUE_ORG` で上書き可）。issue 番号はリポジトリ間で一意でないので、
    `hello-run` には番号ではなく **URL** を渡す。TSV の 1 列目が URL で、fzf には
    `--with-nth=2,3,4` で見せていない。
  - **`gh` の結果だけをキャッシュする。** 実測で `gh search issues` が 1.1〜1.5 秒、
    タブの走査は 0.03 秒なので、遅いのは `gh` だけ。キャッシュ命中で 1.55 秒 → 0.04 秒。
    置き場は `HERDR_PLUGIN_STATE_DIR`（herdr の外では `~/.cache/hello-run`）、TTL は
    `HELLO_RUN_CACHE_TTL` で既定 600 秒。`issues.zsh --refresh` が fzf の `r`、
    `--warm` はプラグインの `[[startup]]` から呼ばれて初回を温める。`gh` が落ちても
    キャッシュがあればそれを見せる。**印はキャッシュに焼かない** — worktree やタブの
    有無は刻々変わるので、毎回その場で付け直す。
  - **一覧の先頭に作業環境の有無を出す**（`●` タブまである / `○` worktree だけ / `・` なし）。
    判定は hello-run が見るのと同じ `<root>/.sessions/issue-<N>` と `issue-<N>` ラベルのタブ。
    **タブは全 workspace を走査する** — hello-run 側と揃えないと印と挙動がずれる。桁揃えは
    fzf がやってくれないので `issues.zsh` が 1 列に組み立て、fzf には `--with-nth=2` で渡す。
  - **fzf は `--disabled` で絞り込みを切ってある。** 候補が十数件で検索が要らないのと、
    切ると ctrl 無しの素のキー（`r` = 再取得）をバインドできるため（`ctrl-r` は端末側の
    履歴検索と当たる）。打った文字が入力欄に残るのを `change:clear-query` で消している。
  - **`gh` のクエリを `pick.zsh` に inline せず `issues.zsh` に分けてあるのは、fzf の `--bind` が
    コンマでバインドを区切るから。** jq のフィルタを `reload(...)` に直接埋めると中のコンマが
    区切りとして食われ、fzf が起動時に `bind action not specified` で rc=2 即死する。popup が
    一瞬開いて閉じる症状になり、`pick.zsh` 側は「選択なし」として 0 で終わるので気づきにくい。
    `tests/herdr/hello-run-plugin.bats` が `reload()` の中のコンマを見張っている。
  - **placement は `popup`**。overlay / split は普通のペインなので閉じるときに元のペインへ
    フォーカスを戻し、`hello-run` が最後に行う `herdr tab focus` と競合する。popup はペインでは
    なくセッション単位のモーダルなのでこれが起きない。
  - **起動は `["zsh", "-l", "pick.zsh"]`**。herdr はシェルを介さず argv を exec するので、
    `~/.zprofile`（brew shellenv）を読ませて `gh`/`fzf`/`wt` を PATH に乗せるために `-l` が要る。
    `-l` は `~/.zshrc` を読まないので、`pick.zsh` は `~/.pzshrc`（`HELLO_RUN_*`）と
    `~/.config/zsh/hello-run.zsh`（関数本体）を自分で source する。
  - **キーバインドは `type = "shell"`**。`keys.command` には `plugin_action` 型しか無く
    plugin pane を直に開く型が無いので `herdr plugin pane open --plugin ... --entrypoint pick`
    を叩く。`[keys.command]` 自体にも `type = "popup"` があるのでプラグインを介さずキーだけで
    同じことはできるが、ログ (`herdr plugin log`) と config ディレクトリが付くプラグイン側を採った。
  - 登録は `install/macos/herdr.sh` が `herdr plugin link ~/.config/herdr/plugins/<name>` で行う
    （`install` ではなく `link` — 本体はこのリポジトリが持つので herdr 側にチェックアウトを
    作らせない）。プラグインを足したらこのスクリプトの `HERDR_PLUGINS` にも足すこと。
    `config.toml` を変えたら `herdr server reload-config`。
  - 対象 org/repo は `hello-run` 同様 `~/.pzshrc` 任せで、`apply.bats` が非混入を検査する。
- **`home/dot_config/herdr/plugins/git-diff/`** は自作の herdr プラグイン
  (`kokikono.git-diff`)。`prefix+Shift+D` でどのペインからでも popup が開き、PR を作る直前の
  差分を GitHub の Files changed のように見る（左が変更ファイルの fzf 一覧、右が `delta` の
  side-by-side）。中身は `herdr-plugin.toml`、`pick.zsh`（fzf）、`files.zsh`（一覧を TSV で
  吐く）、`show.zsh`（1 ファイル分を delta で描く）、`lib.zsh`（共有部分）。知っておくこと:
  - **見せるのは merge-base(origin/<default>, HEAD) からワーキングツリーまで** —
    「PR に載る差分 + 未コミット + 未追跡」。PR を作る直前の確認が用途なのでコミット済みに
    絞らず、未コミットを含むものに `●`、コミット済みのみに `○` を付けて区別する。
  - **popup は元のペインの cwd を引き継がない。** 対象リポジトリは
    `HERDR_PLUGIN_CONTEXT_JSON` の `focused_pane_cwd`（herdr がプラグインの pane に渡す）から
    取り、無ければ `herdr pane list` の `focused` なペインの cwd、それも駄目なら `$PWD`
    （popup 自体は pane list に出ず、popup が開いている間も `focused` は元のペインを指す）。
    git リポジトリでない候補は読み飛ばす。解決した結果は
    `pick.zsh` が `GIT_DIFF_REPO` に入れて子プロセスへ渡す。一覧と preview は別プロセスなので、
    ここで固定しないと preview が別のリポジトリを見にいく。
  - **`-z` の出力をそのまま awk に渡さない。** macOS の awk は `RS="\0"` を扱えず最初の
    レコードしか読まないので、一覧が 1 件に化ける。`files.zsh` は間に `tr '\0' '\n'` を挟む。
  - **`path` という変数名を使わない。** zsh の `$path` は `PATH` と連動する特殊変数で、
    ローカル変数に使うと以降の `tr` / `wc` が command not found になる。
  - **rename は旧パスも `show.zsh` に渡す**（一覧の 3 列目）。片方だけだと git が rename と
    判定せず、中身が変わっていないファイルが「全行追加」に見える。
  - `fzf` の絞り込みは切らない（hello-run と違い候補が数十件になる）。`ctrl-r` で取り直し、
    `enter` で全画面（delta のページャ）。登録と `config.toml` の扱いは hello-run と同じ。
- **`dot_zshrc` is a thin loader.** It bootstraps oh-my-zsh, then sources `~/.config/zsh/{options,aliases,tools}.zsh`
  (in that order — `options.zsh` runs `compinit` before `tools.zsh`'s `compdef`), then `~/.pzshrc`, then
  `git-worktree.zsh`, then `hello-run.zsh`. `options.zsh`=shell opts/history/keybinds, `aliases.zsh`=aliases,
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
- **`home/dot_claude/skills/my-voice/`** teaches Claude to write in the
  author's voice, with one reference per medium: `slack-voice.md` (です/ます + 「！」+ 文末絵文字),
  `formal-voice.md` (Notion 社内文書、常体・数字と表・「今回は着手しないもの」),
  `pr-voice.md` (PR 本文、レビュワー確認ポイントを重い順に). The references are **distilled from real
  Slack / Notion / GitHub content, and this repo is PUBLIC** — every proper noun, URL and concrete
  number must be anonymized to `○○` / `△△` / `（リンク）` before it lands here. Edits don't reach
  `~/.claude/skills/my-voice/` until `chezmoi apply`. `tests/files/apply.bats` guards both the
  deployment and the anonymization.
- **`home/dot_claude/skills/learning-code/`** は AI が書いた PR を「自分で説明できる」状態にするための
  出題・記録スキル (`/learning-code`)。理解度を プロフェッショナル / シニア / ジュニア / ビギナー の
  4 段階で測り、`~/.learning/skills.json` に蓄積する。モードは引数で切り替わる（引数なし=ダッシュボード、
  PR 番号=差分から出題、`review`=復習、`COB`=その日の振り返りと手を動かす演習、領域名=4択5問の初期判定）。
  出題後の解説は `~/.learning/input_logs/YYYY_MM_DD_<summary>.md` に 1 セッション 1 ファイルで残し、
  `COB` がそれと `skills-db.sh tested` の出力を材料に振り返る。**データ本体はリポジトリに入れない** —
  追跡するのは空の雛形 `references/skills.template.json` だけで、`scripts/skills-db.sh init` が
  そこから `~/.learning/skills.json` を作る。JSON の読み書きは必ずこのスクリプト経由にすること
  （昇格は同一 topic で 2 回連続の上位判定が要る、降格は 1 回で 1 段階、という規則がここにしかない）。
  `jq` 必須（Brewfile 済み）。データ置き場は `LEARNING_HOME` で差し替えられ、テストはそれを使う
  (`tests/claude/skills-db.bats`)。出題内容は著者の前提（基本情報技術者 / Web 10 年 /
  react・typescript・laravel・mysql は既知）を踏まえて未知の領域だけに絞る設計で、その前提は
  `references/levels.md` に書いてある。
- **`home/dot_claude/skills/ubiquitous-language/`** は会話に出てきた社内用語を自分用の
  「ユビキタス言語帳」として Notion に蓄積するスキル。**ユーザーの確認を取らずに書き込む**方針
  なので、記録する / しないの線引き (`references/judgment.md`) がこのスキルの本体で、DB の
  プロパティと本文テンプレは `references/schema.md` にある。書き込みは Notion MCP 経由のみで
  `scripts/` は持たない。**追記先の Notion DB ID は追跡しない** — `~/.claude/ubiquitous-language.local.json`
  （非追跡）に `database_url` / `data_source_url` / `glossary_search_hints` / `dry_run` を置き、
  スキルは起動時にそれを読む。
  設定が無ければ `setup` モードで DB を作るところから始まる。`dry_run: true` のあいだは Notion に
  書かず内容を表示するだけなので、発火の調整中はこれを使う。このリポジトリは PUBLIC なので、
  **スキル本文にも references にも社名・プロダクト名・実際の用語を書かない**（例は `○○` / `△△`）。
  `apply.bats` が配備と、32 桁 hex の Notion ID / Notion URL / 社名の非混入を検証する。
- **`home/dot_claude/skills/dev-server/`** は herdr の `dev` label の tab を1つだけ持ち、アプリごとに
  pane を分けて dev サーバーを起動・再利用・停止する運用スキル（`HERDR_ENV=1` 前提）。**追跡するのは
  `SKILL.md` だけで、`references/` は追跡しない。** そこに置くのは「どのアプリをどのコマンドで、
  どのポートで起動するか」という業務リポジトリ固有の表で、アプリ名・内部 URL・環境変数名が並ぶ —
  このリポジトリは PUBLIC なので置けない。匿名化すると「推測せず表を引く」という表の役目自体が
  成立しないため、`my-voice` のように `○○` へ置換する手も使えない。`chezmoi apply` は source に
  無いファイルを消さないので、`~/.claude/skills/dev-server/references/*.md` は手で置いたまま残る
  （マシン入れ替え前に手でバックアップすること）。表に何を書くかは `SKILL.md` に明記してあり、
  `apply.bats` は `references/` が配られないことを検査する。
- **Agent CLI config is tracked too.** `home/dot_claude/` carries the **global instructions**
  (`CLAUDE.md` — a one-line `@AGENTS.md` loader — and `AGENTS.md`, which holds the actual rules;
  Codex / Zed have their own at `home/dot_codex/AGENTS.md` / `home/dot_config/zed/AGENTS.md`),
  `settings.json` (permissions /
  hooks / model / sandbox), `.mcp.json`, `statusline-command.sh`, `hooks/` (`review-before-pr.sh`,
  `herdr-agent-state.sh`, `cbm-*` from codebase-memory-mcp) and `scripts/`
  (`merge-{local,worktree}-permissions.py`, run by the Stop / WorktreeRemove hooks). Only the
  **self-authored** skills are tracked as files (`my-voice`, `optimize-prompt`, `pr-screenshot`,
  `codebase-memory`, `learning-code`, `ubiquitous-language`, `dev-server`). If you add a hook or script referenced from `settings.json`, add it to
  `home/dot_claude/` too — `apply.bats` asserts every name mentioned in `settings.json` is actually
  deployed. The global instructions are for **any** project, so keep employer/project-specific rules
  out of them — this repo is PUBLIC and `apply.bats` greps them for leaked proper nouns.
- **外部スキルは lock だけを管理する（本体は vendoring しない）。** `agent-browser` /
  `design-doc-mermaid` / `find-skills` / `grill-me` / `herdr` / `humanizer-ja` / `show-me` は
  [`npx skills`](https://skills.sh/) で入れたもので、台帳は `~/.agents/.skill-lock.json`。その
  コピーを **`install/macos/skills-lock.json`** に置き、`install/macos/skills.sh` が各エントリを
  `npx -y skills@latest add <source> -g -s <name> -a claude-code -y` で復元する（導入済みは
  スキップ、失敗しても他を止めない）。台帳の更新は:

  ```
  cp ~/.agents/.skill-lock.json install/macos/skills-lock.json
  ```

  `skills experimental_install` は **project スコープの `skills-lock.json` 用**でグローバル
  (`~/.agents/.skill-lock.json`) は読まないので、復元はこのスクリプトが担う。なお現行 CLI
  (1.5.24) は `~/.claude/skills/<name>/SKILL.md` に実ファイルを書く。この Mac に残っている
  `~/.claude/skills/x -> ~/.agents/skills/x` の symlink 構成は**旧版の名残**なので、新マシンでは
  再現されない（そのため chezmoi では symlink を追跡していない）。
  **残るリスク:** upstream が消えるとスキルも失われる。`grill-me` / `humanizer-ja` などは個人
  リポジトリなので、内容に依存しているものは自前スキルとして `home/dot_claude/skills/` に
  取り込むほうが安全。
- **These files are rewritten by the apps themselves**, so `chezmoi status` will show drift over
  time: `.claude/settings.json` (Claude Code writes model/plugin/permission changes),
  `.codex/config.toml`, `.gemini/settings.json`, `.config/zed/settings.json`. Resolve with
  `chezmoi re-add <path>` (adopt the live version) rather than `chezmoi apply`. `dot_codex/config.toml`
  intentionally drops codex's `[projects.*]` / `[hooks.state]` blocks — machine-local trust state
  that is meaningless on a new machine (and would leak private repo paths into this PUBLIC repo);
  `apply.bats` guards that.
- **Not tracked on purpose** (needs manual backup before a machine reset): `~/.pzshrc`, `~/.npmrc`
  (contains live tokens), `~/.ssh`, `~/.gnupg`, `~/.aws/config`, `~/.config/gh/hosts.yml`,
  `~/.config/gcloud`, `~/.config/op`, `~/.config/git/signing.conf` (generated by `install/macos/gpg.sh`), `~/.learning/`
  (the learning-code skill's mastery data and explanation logs — personal, and this repo is PUBLIC;
  only the empty template ships; see the learning-code entry above),
  `~/.claude/ubiquitous-language.local.json` (the ubiquitous-language skill's Notion DB id and
  search hints — workspace-specific, and this repo is PUBLIC),
  `~/.claude/skills/dev-server/references/` (per-repo start commands / ports / internal URLs — see
  the dev-server entry below), and `~/Library/Preferences/com.googlecode.iterm2.plist`
  (binary, rewritten on every iTerm2 quit).

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
