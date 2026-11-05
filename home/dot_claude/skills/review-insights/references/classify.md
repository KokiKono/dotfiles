# レビューコメントの分類基準

`pending.jsonl` の 1 レコード = 1 コメント。まず `in_reply_to_id` でスレッドに束ね、**root + 返信をまとめて 1 件の「指摘」**として扱う。返信は、指摘が受け入れられたか突き返されたかを読むために使う。

各レコードのフィールド: `id` / `kind`(inline|pr_comment|review) / `source`(human|claude-review) / `pr` / `pr_author` / `author` / `path` / `line` / `url` / `created_at` / `body`。

## verdict の決め方

### `stack` — 未カバーの規約として積む

次を全て満たすもの。

- **一般化できる**。この PR のこの行だけの話ではなく、次に同じ領域を書く人にも効く
- **守るべきことが言える**。「〜する」「〜しない」の形に落ちる
- **agent ファイルに書かれていない**。配置先候補ファイルの全文とルート `CLAUDE.md` を読んだ上で判断する

### `covered` — 既に書かれている

既存の記述と同じことを言っている。`reason` に、どのファイルのどの記述と重なるかを書く。

表現が違っても意図が同じなら covered。例: 「`Time.now` ではなく `Time.current`」がルートの `CLAUDE.md` の日時の節に既に書いてある。

既存の記述より**明確に踏み込んでいる**場合（条件が追加されている、例外が示されている）は covered にせず stack し、`rule` に差分だけを書く。

### `noise` — 捨てる

- 質問、実装相談、仕様の確認
- 「対応しました」「ありがとうございます」等の進捗・謝辞
- assign 依頼、リリース調整、Slack への誘導
- この PR 固有のロジック指摘で、他に一般化できないもの
- typo 指摘、リンク切れ
- lint が機械的に検出できるもの（rubocop / oxc / tsc が落とす規約）
- 返信で前提が覆り、**対応不要として解決された**指摘。指摘が外れていたという意味なのでルールにしない
- claude-review が次の push で投稿する「解消済みと判断しました」の確認コメント

## `rule` の書き方

- **1 行**。命令形。主語を省かない
- What（何を満たすべきか）を書く。How（どう直すか）は書かない
- 固有名詞は残す。「外部 API」ではなく「○○ の決済 API」のように、どの文脈で効くかが分かる粒度にする
- コメントの言い回しをそのまま写さない。次に同じコードを書く人が読んで守れる文にする

良い例:
- `enum は prefix: true にして、自動生成メソッドの名前衝突を避ける`
- `店舗の現地時刻をパースするときは、固定の時差ではなく店舗のタイムゾーンを指定する`

悪い例:
- `ここは修正した方が良さそうです`（指摘がそのまま）
- `タイムゾーンに気をつける`（守れる粒度になっていない）

## `target_file` の決め方

1. コメントの `path` を、そのリポジトリの `.claude/rules/*.md` の frontmatter `paths:` と突き合わせる。マッチしたファイルを候補にする
2. マッチしない、または `path` が null（PR 全体コメント）なら、ルートの `CLAUDE.md`
3. サブディレクトリに `CLAUDE.md` / `AGENTS.md` があるリポジトリでは、その配下への指摘はそのファイルも候補になる
4. どの rules ファイルにも属さないが明確に領域が立つ指摘（新しい rules ファイルが要る）は、`target_file` を `.claude/rules/<新しい名前>.md` にして提案する

## `source` の扱い

`claude-review`（bot）由来の指摘は、既に CI のプロンプトが拾えているということでもある。ただし**同じ指摘が繰り返し出ている**なら、それはルール化されていないから毎回指摘されているという意味なので stack する価値がある。

human と claude-review が同じことを言っていたら同一エントリに merge する。backlog.md は内訳を分けて表示する。

## 出力

`stack.sh apply` に渡す配列。`pending.jsonl` の全 `id` が、いずれかのエントリの `comment_ids` にちょうど 1 回現れること。

```json
[
  {"verdict":"stack",
   "comment_ids":["inline:4279601903","inline:4279628237"],
   "rule":"○○ の決済 API のエラーコードは一律に非通知にせず、項目名で始まるメッセージだけをユーザー起因として扱う",
   "target_file":".claude/rules/controller.md",
   "merge_into":null,
   "evidence":{"pr":46036,"url":"https://github.com/<org>/<repo>/pull/46036#discussion_r4279601903",
               "date":"2026-10-15","author":"reviewer-bot","source":"claude-review",
               "excerpt":"○○ の INVALID_REQUEST を一律に非通知にすると、自社側の連携不具合に気づけなくなる"}},
  {"verdict":"covered","comment_ids":["inline:4279632066"],"rule":"Time.now を使わない",
   "reason":"CLAUDE.md「日時・タイムゾーン」に同じ記述がある"},
  {"verdict":"noise","comment_ids":["issue:6185038900"],"rule":null,"reason":"Slack への誘導で規約ではない"}
]
```

**別の PR で観測した同じルールは、classified.json のエントリも分けて `merge_into` でつなぐ。** 1 エントリに複数 PR の `comment_ids` をまとめると `count` が 1 しか増えず、昇格候補に上がらない。同じ PR の中の root と返信は 1 エントリにまとめてよい。

`evidence.excerpt` は 150 字以内。`evidence.url` はコメントのパーマリンク（レコードの `url`）。
