---
name: multi-review
description: claude・gemini・grok の 3 つの CLI に同じ差分を並列でレビューさせ、結果を 1 つのレポート（複数のモデルが挙げた指摘、見解が割れた指摘、参考）にまとめる。「マルチレビューして」「3 モデルでレビュー」「gemini と grok にもレビューさせて」「multi-review」「別のモデルにも見てもらって」などと言われたときに使う。手元のブランチの差分でも PR 番号でも使える。1 モデルでのバグ探しなら /code-review、FE と BE の突き合わせなら cross-review を使う。
argument-hint: "[--pr <番号|URL>] [--base <ref>] [--only claude,gemini,grok] [--focus <観点>] [--untracked]"
---

# multi-review

同じ差分を claude・gemini（Antigravity CLI の `agy`）・grok に独立にレビューさせ、claude が 1 つのレポートにまとめる。
モデルごとに見落とす所が違うので、複数のモデルが挙げた指摘は信用でき、1 つだけが挙げた指摘は確かめる価値がある。

実体は `scripts/multi-review.sh`（ターミナルからは `multi-review` で呼べる）。このスキルはそれを呼んで結果を読むだけ。

## 1. 実行する

引数はそのまま渡す。3 モデルが並列に走るので数分かかる。Bash の `run_in_background` で流し、終わるのを待つ。

```bash
~/.claude/skills/multi-review/scripts/multi-review.sh [引数]
```

| 引数 | 意味 |
|---|---|
| （なし） | merge-base(origin/<既定ブランチ>, HEAD) から作業ツリーまで。未追跡のファイルは含めず、名前だけを標準エラーに出す |
| `--untracked` | 未追跡のファイル（.gitignore 以外）も載せる。3 社の外部サービスに送られるので、中身を確かめてから付ける |
| `--pr <番号\|URL>` | `gh pr diff` の差分 |
| `--base <ref>` | 比べる起点 |
| `--only claude,grok` | 使うレビュアーを絞る |
| `--focus <観点>` | 特に見てほしい観点をプロンプトに足す |
| `--timeout <秒>` | レビュアーごとの上限（既定 900） |
| `--no-merge` | まとめずに各レビュアーの出力だけ残す |

モデルは環境変数 `MULTI_REVIEW_{CLAUDE,GEMINI,GROK,MERGE}_MODEL` で変えられる（無ければ各 CLI の既定）。grok の推論量は `MULTI_REVIEW_GROK_EFFORT`（`--effort` に渡す）で変えられる。

標準出力に `report.md` が出る。結果のディレクトリ（標準エラーの最後の行）には、差分・プロンプト・
レビュアーごとの出力（`<name>.md`）とログ（`<name>.log`）が残る。

## 2. 結果を伝える

- レポートをそのまま貼らず、重大度「高」と、複数のモデルが挙げた指摘を先に要約する
- 1 つのモデルだけが挙げた指摘と「見解が割れている指摘」は、コードを読んで当たっているか確かめてから伝える。
  まとめ役の claude は指摘を足しも削りもしない設定なので、外れた指摘もそのまま残っている
- 失敗・スキップしたレビュアーがあれば理由（`<name>.log`）を添える。未インストールなら
  `brew install --cask antigravity-cli`（agy）のように入れ方を、未ログインなら各 CLI でのログインを案内する
- 指摘を直すかどうかはユーザーに任せる。頼まれるまで直さない
