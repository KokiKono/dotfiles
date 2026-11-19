---
name: report-my-channel
description: 指示された報告書（調査結果・状況まとめ・定期レポートなど）を作り、詳細を Notion の個人メモ DB に「種別 = AIレポート」のページとして書き、Slack の自分用メモチャンネルには概要だけを投稿する。「〜をレポートして」「報告書にまとめて自分のチャンネルに流して」「memo チャンネルに報告して」「毎朝〜を報告して」「定期的にレポートして」「ルーティンにして」などと言われたときに使う。結果を Slack と Notion の両方に残したい話や、報告を定期実行にしたい話なら、スキル名を言われなくても使うこと。社内の資料を調べて答えるだけなら hello-search、他人に向けた Slack 文面の下書きなら my-voice を使う。
argument-hint: "<報告してほしいこと> [毎朝9時 などの頻度] | run <依頼> | routines | setup"
---

# report-my-channel

頼まれた報告を作り、**詳細は Notion、概要は Slack** に分けて置く。
Slack は通知を見て「今読むか、後でいいか」を決める場所で、Notion は後から読み返す場所なので、
同じ中身を両方に貼らない。Slack には Notion へのリンクを必ず付ける。

形の決まりは参照ファイルにある。書く直前に読む。`run` で読むのは最初の 2 つだけでよい。

- `references/notion.md` — Notion のページの形（目次・図・外部リンク・見出しの色）
- `references/slack.md` — Slack の投稿の形（優先度・装飾）
- `references/routine.md` — 定期実行にするとき（§6 と `routines` のときだけ読む）

## 0. 設定を読む

`~/.claude/report-my-channel.local.json` を Read で読む（launchd からの `run` では `cat` などの Bash を許していない）。

| キー | 意味 |
|---|---|
| `slack_channel_id` | 投稿先チャンネルの ID（`#memo-…` の ID） |
| `database_url` | 個人メモ DB |
| `data_source_url` | その data source（`collection://…`）。`notion-create-pages` の親に渡す |
| `dry_run` | `true` なら Notion にも Slack にも書かず、書く内容を表示するだけ |

**このファイルは追跡外**（このスキルは public リポジトリにある）。無ければ `setup` モードへ。
ルーティンから呼ばれたときは、プロンプトに同じ値が埋め込まれているのでそれを使う。

## 1. 依頼を読み分ける

| 引数 | 動き |
|---|---|
| 報告してほしいことだけ | 今 1 回作って投稿する（§2〜§5） |
| 頻度・時刻を含む（「毎朝」「平日 18 時」「毎週月曜」） | 1 回目を今作って見せ、それからルーティンにする（§6） |
| `run <依頼>` | ルーティンからの実行。確認を挟まず §2〜§5 を通す |
| `routines` | 作ったルーティンの一覧を出す（§6 の末尾） |
| `setup` | 設定を作る（下の setup モード） |

報告の中身（何を調べ、何を数えるか）が曖昧なら、作り始める前に 1 回だけ聞く。
ルーティンにする依頼では特に、毎回同じ基準で集められるか（期間・対象・件数の数え方）を先に決める。
基準が回ごとにぶれると、前回との比較ができない。

## 2. 材料を集めて報告を組み立てる

依頼に応じて Slack・Notion・GitHub・ローカルのファイルなどを読む。社内の議論を横断で調べる依頼なら
hello-search の検索の進め方（`~/.claude/skills/hello-search/references/sources.md`。クラウドでは `home/dot_claude/skills/hello-search/references/sources.md`）に沿ってよい
（登録はこのスキルの形で行う）。

組み立てる前に、次の 3 つを決める。Slack と Notion の両方がこれを元に書かれる。

- **結論**: 1〜2 文。読み手が最初に知るべきこと
- **優先度**: 🔴 今日中に対応 / 🟡 今週中に確認 / 🟢 共有のみ。基準は `references/slack.md`
- **次の行動**: 自分が取るべき行動。無ければ「なし」と書く（無いことも判断材料になる）

**読んでいないものを書かない。** 検索結果の抜粋やタイトルから中身を推し量らない。
事実には出典のリンクと日付を付ける。推測は推測と書いて分ける。

## 3. Notion に詳細を書く

`references/notion.md` の形で、個人メモ DB に `種別 = AIレポート` のページを作る。
本文は書き終えたら投稿の前に **yomiyasu スキルで推敲する**（新規作成として、読み手は
「この報告の経緯を何も知らない未来の自分」）。yomiyasu が入っていない環境（クラウドのルーティン）では、
`references/notion.md` の「ゼロコンテキストで読める書き方」を自分で当ててから書く。

## 4. Slack に概要を投稿する

`references/slack.md` の形で、Notion のページへのリンクを付けて `slack_send_message` で投稿する。
投稿先は自分用のメモチャンネルで、自分から頼まれた報告なので、**投稿前の確認は取らない**
（ルーティンでは確認できる人がいない）。Notion を作れなかったときは Slack にもそう書く。
Notion が無いまま詳細を Slack に貼ると、概要だけに留める決まりが崩れるため。

## 5. 結果を返す

```
📝 Notion:「<タイトル>」（リンク）
💬 Slack: #<チャンネル名> に投稿（メッセージのリンク）
```

`dry_run` のときは、作るはずだった Notion の本文と Slack の文面を表示して終える。

`run` のときは、最後の行を `REPORT: OK`（Notion と Slack の両方に書けた、または `dry_run`）か
`REPORT: NG <理由>` にする。`claude -p` は投稿に失敗しても正常終了するので、launchd 側はこの行で成否を見て通知する。

## 6. ルーティンにする

`references/routine.md` を読んで進める。ルーティンを作ったセッションは閉じられる前提なので、
`/loop` やセッション内の cron（CronCreate）は使わない。

## setup モード

1. Slack のチャンネルを `slack_search_channels` で名前から探し、ID を取る（既定は `memo-` で始まる自分のチャンネル）
2. Notion の DB は hello-search / ubiquitous-language と同じ個人メモ DB を使う。
   `~/.claude/hello-search.local.json` があれば `database_url` / `data_source_url` を流用してよいか聞く
3. その data source を fetch し、`種別` に `AIレポート` の選択肢があるか確かめる。無ければ足してよいか聞く
4. `~/.claude/report-my-channel.local.json` に書く。`dry_run` は最初 `true` にし、1 回ためしてから `false` にするよう勧める

## 守ること

- **Slack に詳細を貼らない。** 長い表・全件の一覧・根拠の引用は Notion に置き、Slack には要点とリンクだけ
- **投稿先は設定のチャンネルだけ。** 他のチャンネルや他人の DM には投稿しない
- **社内の固有名詞・ID をこのスキルのファイルに書かない。** チャンネル ID・Notion の ID は
  追跡外の設定とルーティンのプロンプトにだけ置く。例が要るときは `○○` / `△△` にする
