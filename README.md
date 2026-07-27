# dotfiles

[chezmoi](https://chezmoi.io) で管理する **macOS 専用**の個人 dotfiles。zsh / git / VS Code の設定を
`home/` に置き、`chezmoi apply` で `$HOME` へ展開する。マシンのセットアップ（Homebrew, mise, oh-my-zsh,
VS Code 拡張）は `install/` 配下の小さなシェルスクリプトが担い、[Bats](https://github.com/bats-core/bats-core)
と GitHub Actions でテストしている。

設計は [testable-dotfiles-management-with-chezmoi](https://zenn.dev/shunk031/articles/testable-dotfiles-management-with-chezmoi)
を参考にしている。

## 新しいマシンでのセットアップ

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply KokiKono
```

初回は名前とメールを聞かれ（`~/.gitconfig` に反映）、続けて `chezmoi apply` が走る。この apply で
`install/macos/{brew,mise,ohmyzsh,nodenv,vscode}.sh` が順に実行され、以下が入る:

- **Homebrew** + `brew bundle`（`Brewfile` の ~110 パッケージ）
- **mise** のツール（`mise install`）
- **oh-my-zsh**
- **nodenv-yarn-install** プラグイン
- **VS Code 拡張**（`install/macos/vscode-extensions.txt`）

## 日常の使い方

このリポジトリのファイルを編集しても、`chezmoi apply` するまで `$HOME` には反映されない（シンボリック
リンク方式ではない点に注意）。

```sh
chezmoi edit ~/.zshrc          # ソース(home/dot_zshrc)を編集
chezmoi diff                   # 反映前に差分を確認
chezmoi apply                  # $HOME へ反映（install スクリプトも再実行され得る）
chezmoi apply --exclude scripts  # ファイルだけ同期（brew 等の重い処理をスキップ）
chezmoi status                 # ソースと $HOME の差分状態
```

リポジトリ側で直接編集した場合は `chezmoi apply` で取り込む。逆に `$HOME` 側で変わったものを取り込む
ときは `chezmoi re-add`。

## ディレクトリ構成

```
.chezmoiroot                       # "home"（chezmoi のソースディレクトリ指定）
home/                              # chezmoi ソース（$HOME に展開される）
├── dot_zshrc                      # → ~/.zshrc（薄いローダー: oh-my-zsh + zsh モジュール読込）
├── dot_gitconfig.tmpl             # → ~/.gitconfig（name/email をテンプレート化）
├── dot_gitignore_global           # → ~/.gitignore_global
├── dot_config/mise/config.toml    # → ~/.config/mise/config.toml（node/python/java 固定）
├── dot_config/zsh/{options,aliases,tools}.zsh  # 分割した zshrc（挙動 / エイリアス / env+mise+wtp+gcloud）
├── dot_config/zsh/git-worktree.zsh # → ~/.config/zsh/...（wrm/brm/bd。dot_zshrc から source）
├── Library/Application Support/Code/User/{settings,keybindings}.json  # VS Code
└── .chezmoiscripts/run_onchange_install.sh.tmpl  # apply 時に install/ を実行
install/
├── common/lib.sh                  # 共通ヘルパー（REPO_ROOT, log, has）
└── macos/{brew,mise,ohmyzsh,nodenv,vscode}.sh
tests/                             # Bats テスト（install スクリプト単体 + apply E2E）
.github/workflows/ci.yml           # macOS CI（bats + apply E2E、週次でフルセットアップ）
```

## バージョン管理（mise）

Node / Python / Java は [mise](https://mise.jdx.dev) に統合している。固定バージョンは
`home/dot_config/mise/config.toml` に宣言:

```toml
[tools]
node = "22.16.0"
python = "3.11.6"
java = "temurin-11"
```

`.zshrc` では `eval "$(mise activate zsh)"` の1行のみ。Go は Homebrew、Ruby は macOS system を利用。
バージョンを変えるときはこの TOML を編集し `chezmoi apply` → `mise install`。

## worktree / ブランチのクリーンアップ

`home/dot_config/zsh/git-worktree.zsh`（`.zshrc` から自動 source）が3つの関数を提供する。
依存: `fzf`（全部）, `gh`（`wrm`）。worktree の**作成・移動**は別途 `wtp` を使う。

| 関数 | 説明 |
|------|------|
| `wrm` | PR が **MERGED**（または PR 無し）の worktree を一括削除。`gh auth status` チェックと y/N 確認あり |
| `brm` | デフォルトブランチにマージ済み、または上流が `[gone]` のローカルブランチを削除（`git fetch --prune` 後、確認あり） |
| `bd`  | `fzf` で選んでブランチ削除。MERGED/UNMERGED プレビュー付き。保護ブランチ（main/master/dev/develop/staging/production）と worktree 使用中は除外 |

デフォルトブランチは `origin/HEAD` から自動判定（無ければ main → master）するため、複数リポジトリで
そのまま使える。参考: [git-worktree-fzf-branch-cleanup](https://www.playpark.co.jp/blog/git-worktree-fzf-branch-cleanup)。

## テスト

```sh
brew install bats-core chezmoi   # 前提
bats -r tests/                   # 全テスト実行
```

- `tests/install/macos/*.bats` … 各 install スクリプトの構文・関数定義・prereq 不在時の skip
- `tests/files/apply.bats` … 使い捨て `$HOME` へ `chezmoi apply --exclude scripts` し、展開結果を検証
- `tests/files/git-worktree.bats` … クリーンアップ関数の `zsh -n` 構文チェックと関数定義
- `tests/files/zsh-modules.bats` … 分割した zsh モジュール（options/aliases/tools）の構文チェック

install スクリプトを追加したら、対応する `tests/install/macos/<name>.bats` も追加する。
`@test` のタイトルは **ASCII のみ**（bats が多バイト文字を壊すため。日本語はコメントに書く）。

## 各種パッケージ・拡張の更新

```sh
brew bundle dump --force                                    # Brewfile を再生成
code --list-extensions > install/macos/vscode-extensions.txt  # VS Code 拡張リストを更新
```

## シークレット

マシン固有の秘密情報は `~/.pzshrc`（`.zshrc` の末尾で source、chezmoi 管理外）に置く。追跡ファイルには
絶対にコミットしない。
