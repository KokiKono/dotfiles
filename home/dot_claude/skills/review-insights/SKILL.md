---
name: review-insights
disable-model-invocation: true
description: Use when the user says "review-insights" or "レビュー知見をスキャンして" — 他人のものも含む PR のレビューコメントを差分スキャンし、各リポジトリの agent ファイル（CLAUDE.md / .claude/rules/*.md）で未カバーの指摘だけを backlog に stack する。頻出したものと自分の PR への指摘は、毎朝の自動実行で個人ルール（~/.claude/rules/review-insights/）に昇格する。"review-insights check" で差分をそのルールに照らして確かめる。
---

PR のレビューコメントには、まだどの agent ファイルにも書かれていないチームの暗黙知が流れ続けている。それを拾って溜め、頻出するものと自分が指摘されたものをルールに昇格させることで、同じ失敗を最初の 1 回目から防ぐ。

データは全て `~/.claude/review-insights/` 配下。**対象リポジトリの working tree は一切触らない**（agent ファイルは `git show origin/<既定ブランチ>:…` で写して読む）。

スクリプトは `~/.claude/skills/review-insights/scripts/`:

- `daily.sh` — launchd（`com.kokikono.review-insights`、毎朝 9:03）が呼ぶ自動実行。下の「自動実行」を参照
- `fetch-comments.sh <repo> [--since 14d|ISO] [--limit N]` — GitHub の `since` カーソルで未読のレビューコメントだけを取得し `pending.jsonl` に出す。**cursor は進めない**
- `state.sh commit <repo>` — 分類が終わってから cursor と seen_ids を確定させる
- `stack.sh apply <repo> <classified.json>` — 分類結果を backlog.json に upsert し backlog.md を再生成する
- `stack.sh list|status|promote <repo>` — 昇格候補の取得・状態更新
- `stack.sh decide <repo> <decisions.json>` / `stack.sh rules <repo>` — 昇格の判定を反映し、個人ルールのファイルを作り直す
- `paths.py` — ルールの適用範囲（glob）を分類先から決め、変更ファイルと照合する
- `check.sh [PR番号 | --base <ref>]` — 差分を個人ルールに照らして確かめる。下の「check」を参照

repo キーは `~/.claude/review-insights/config.json` の `repos` のキー。

## 自動実行（daily.sh）

LLM を呼ぶのは takt の WF 2 本だけで、モデルは `takt/runtime.yaml` が step ごとに振り分ける。
takt の作業ディレクトリは `~/.cache/review-insights/`（`~/.claude` の下は step から書けないため）。LLM に渡す入力はそこに写し、出力もそこから読み戻す。
取得・検証・backlog の更新・cursor の確定はスクリプトが行う。

| 段階 | 担当 | モデル |
|---|---|---|
| 取得、agent ファイルの写し | `fetch-comments.sh`、`daily.sh` | なし |
| 明らかな noise を落とす | `review-classify` の `triage` | haiku |
| 残りを規約として分類 | `review-classify` の `classify` | sonnet |
| 全件を 1 回ずつ網羅しているか検証、backlog に反映、cursor を確定 | `daily.sh`、`stack.sh apply`、`state.sh commit` | なし |
| 昇格候補を個人ルールに載せるか判定 | `review-promote` の `promote` | sonnet |
| 適用範囲（`paths`）を分類先のルールファイルから決め、個人ルールを書き出す | `paths.py`、`stack.sh decide` | なし |

- 昇格候補は、`count` が `promote_min`（既定 3）以上のものと、**`self_login` の PR に付いた指摘（1 件でよい）**
- 個人ルールは `~/.claude/rules/review-insights/auto-<repo>-*.md` に、適用範囲ごとに分けて書く。
  分類先（`target_file`）が業務リポジトリの `.claude/rules/*.md` ならその `paths:` を、サブディレクトリの
  `CLAUDE.md` / `AGENTS.md` ならそのディレクトリを、先頭に `**/` を付けて frontmatter の `paths:` にする。
  こうしたファイルは該当するファイルを触ったときだけ読み込まれる
- ルートの agent ファイル向けの横断ルールは `auto-<repo>-common.md`（`paths:` なし。常に読まれる）に、
  件数の多い順で `always_max`（既定 10）件まで入れる。入りきらないものは check が差分を見て選ぶ
- `auto-` で始まらないファイルと `~/.claude/rules/review-insights.md` は手書き用で、触らない
- 実行ログは `~/.claude/review-insights/log/<日付>.log`。個人ルールが変わった日は末尾に `diff -u` が出る。
  変更前の写しは `history/` に 60 日残る
- 自動で載ったルールを外すときは `stack.sh promote <repo> <id> rejected` → `stack.sh rules <repo>`。
  一度 rejected / promoted にしたエントリは自動実行で上書きされない

## check（差分を個人ルールに照らす）

`/review-insights check [PR番号]` と呼ばれたら、対象リポジトリのディレクトリで実行して出力をそのまま見せる。
PR 番号が無ければ、既定ブランチとの merge-base から作業ツリーまで（未コミットを含む）を見る。

```bash
~/.claude/skills/review-insights/scripts/check.sh [PR番号 | --base <ref>]
```

**Bash ツールの timeout は 600000 にする。** takt の WF `review-check` を流すので数分かかる。

- `paths` で当たるルールは `paths.py match` が機械的に拾う（LLM を使わない）
- 横断ルールは `select`（haiku）が差分に関係しそうなものを選ぶ
- `review`（sonnet）がそれらのルールだけを差分と照合し、`findings.md` に書く。一般的なレビューはしない
  （そちらは `/code-review`）
- 照合するルールが 1 件も無ければ takt を呼ばずに終わる

違反の疑いを直すかどうかはユーザーに確かめる。勝手に直さない。

## scan（既定の動作。引数なしで呼ばれたらこれ）

config.json の各リポジトリについて 1〜4 を回す（手動で走らせるとき。毎朝の分は daily.sh が行う）。1 リポジトリで失敗しても残りは続ける。**どれか 1 つでも未処理のまま turn を終えない。** 失敗したリポジトリは理由を報告に書く。

### 1. 取得

```bash
~/.claude/skills/review-insights/scripts/fetch-comments.sh <repo>
```

**このコマンドは Bash ツールの timeout を 600000 にして実行する。** PR ごとに GitHub API を引くので、初回の 14 日分バックフィルでは 1 分以上かかる。既定の 2 分でタイムアウトさせると、そのリポジトリだけ処理されないまま scan が終わる。タイムアウトしたら同じコマンドを長い timeout で実行し直す（cursor は進んでいないので取り直しになるだけ）。

出力 JSON の `pending` が 0 なら、そのリポジトリは `state.sh commit` だけして次へ進む（新着なし）。
`deferred` が 0 より大きいときは上限で切られた持ち越しがあるという意味で、異常ではない。次回のランで続きを読む。

### 2. 分類

`~/.claude/skills/review-insights/references/classify.md` を読み、`pending.jsonl` の各レコードを判定する。判定基準はそちらに全て書いてある。

判定の前に、そのリポジトリの agent ファイルを読んでおく（既出かどうかの判定に要る）:

```bash
cd <repo path> && cat CLAUDE.md && head -5 .claude/rules/*.md
```

`.claude/rules/*.md` は frontmatter の `paths:` で適用範囲が決まる。コメントの `path` と突き合わせて配置先候補を選び、**その候補ファイルの全文**とルート `CLAUDE.md` を読んでから既出かを判定する。

既存 backlog との同義判定のため、`stack.sh list <repo> 1` で現在のエントリも見ておく。同義なら `merge_into` にその `id` を入れる。

### 3. stack

分類結果を配列の JSON にしてスクラッチに書き、適用する:

```bash
~/.claude/skills/review-insights/scripts/stack.sh apply <repo> /path/to/classified.json
```

JSON の形は `stack.sh` を引数なしで実行すると出る。`pending.jsonl` の全レコードが、いずれかのエントリの `comment_ids` に 1 回だけ現れること。取りこぼすと次回も再判定されないまま消える。

### 4. 確定

```bash
~/.claude/skills/review-insights/scripts/state.sh commit <repo>
```

**`stack.sh apply` が成功した後にだけ実行する。** 先に commit すると、分類に失敗したコメントが既読扱いで永久に失われる。

### 5. 報告

リポジトリごとに「取得 N 件 / 新規 stack N 件 / 既出で破棄 N 件 / 昇格候補 N 件」を 1 行で報告する。昇格候補が増えていたら、そのルール文も挙げる。

## status

```bash
for r in $(jq -r '.repos | keys[]' ~/.claude/review-insights/config.json); do
  ~/.claude/skills/review-insights/scripts/stack.sh status "$r"
done
```

backlog.md のパスと昇格候補の件数を報告する。

## promote

`stack.sh list <repo>` で出た昇格候補（既定で 3 件以上）を rules に反映する提案を作る。

1. 候補ごとに `target_file` の全文を読み、**そのファイルの既存の文体・粒度に合わせた**追記案を書く。業務リポジトリの `.claude/rules/*.md` は多くの場合「ルール 1 行 +（必要なら）短いコード例」。背景説明や経緯は書かない
2. 追記案を diff の形でユーザーに見せ、どこに適用するかを聞く（対象リポジトリに書いて PR にする / 個人用ルールに留める / 却下）
   - 個人用ルールの置き場所は `~/.claude/rules/review-insights.md`（`~/.claude/AGENTS.md` から `@rules/review-insights.md` で読み込んでいる）。リポジトリごとの見出しの下に置き、グローバルに読まれるので見出しで適用範囲を示す
3. **承認を得てから**適用する。コミット・push・PR 作成は毎回ユーザーの確認を取る
4. 適用したものは `stack.sh promote <repo> <id>`、却下は `stack.sh promote <repo> <id> rejected` で状態を更新する。あわせて backlog.json のそのエントリに `promoted_to`（適用先のパス）と `promoted_at` を書く

ユーザーが明示的に promote を頼むまで、このフェーズは実行しない。
