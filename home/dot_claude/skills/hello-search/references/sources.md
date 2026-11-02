# ソースごとの検索のコツ

どのソースも「検索 → 上位を開いて全文を読む」の 2 段で使う。抜粋だけで判断しない。

## Slack

- `slack_search_public_and_private` を使う（public だけだと、決定が DM や private チャンネルにあるとき見落とす）
- クエリ構文:
  - `"完全一致の語句"`
  - `in:#channel` / `from:<@UXXXX>` / `after:YYYY-MM-DD` / `before:YYYY-MM-DD`
  - `has:link`（Notion や PR へのリンクを含む投稿だけにする）
- 日本語は形態素の区切りでヒットが変わる。長い語で外れたら短い語に分けて投げ直す
- ヒットしたらその投稿だけでなく `slack_read_thread` でスレッド全体を読む。結論は最後の方の返信にあることが多い
- 設定の `slack_channel_hints` があれば、最初に `in:` で絞った検索を 1 本混ぜる
- 出典リンクはメッセージの permalink を使う

## Notion

- `notion-search` で検索する。仕様書・議事録・設計メモが主な対象
- ヒットしたページは `notion-fetch` で本文を読む。`truncated` が出たら必要な部分まで追う
- 更新日を見る。古い仕様ページが更新されずに残っていることが多いので、Slack や PR の日付と突き合わせる
- 議事録は `notion-query-meeting-notes` の方が日付で絞りやすい
- 個人メモ DB（設定の `data_source_url`）も過去の調査として検索対象に含める。
  同じテーマを前に調べていれば、それを起点にして差分だけ探す

## GitHub

`--owner` には設定の `github_owner` を渡す。リポジトリをまたいで探すため `--repo` で絞らない。

```bash
gh search issues "<語>" --owner <org> --limit 20 --json url,title,state,updatedAt,repository
gh search prs    "<語>" --owner <org> --limit 20 --json url,title,state,updatedAt,repository
gh search code   "<識別子>" --owner <org> --limit 20 --json path,repository,url
```

- 当たった issue / PR は `gh issue view <url> --comments` / `gh pr view <url> --comments` で読む。
  議論はコメントにあり、本文は最初の案のままのことが多い
- PR は「なぜこう実装したか」の一次資料。説明文とレビューのやりとりを読む
- `gh search code` は default branch しか見ない。未マージの変更は PR 側で探す

## kb

hello-run のセッションと共有しているローカルの知見置き場（設定の `kb_path`）。

```bash
rg -n -i "<語>" ~/git_clone/local/kb
```

`issues/<repo>-<N>/README.md` に issue ごとの調査メモがある。他のセッションが同じ issue を調べていれば、ここに先に答えがある。

## 見つからないとき

- 検索語を英語 / 日本語 / 略語で入れ替える
- 人で探す: 関係しそうな PR の author や Slack の発言者を特定し、`from:` で絞る
- それでも無ければ、どこを何で探したかを書いて「見つからなかった」と報告する。無理に埋めない
