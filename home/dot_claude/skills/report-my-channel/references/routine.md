# ルーティンにする

ルーティンを作ったこのセッションは、すぐ閉じられるかもしれない。だから**ルーティンは単体で動く**ように作る。

- `/loop` と CronCreate は使わない。どちらもセッションが生きている間しか動かない
- 依頼の文面・設定値・スキルの在りかを、すべてルーティンのプロンプトに書く。
  「さっきの会話のとおりに」のような、このセッションの文脈に頼る書き方をしない
- 1 回目は今このセッションで作って投稿し、形をユーザーに見てもらってから登録する。
  登録した後で形を直すと、ルーティンのプロンプトも直す手間が増える

## どちらで動かすか

| 報告に要るもの | 置き場 |
|---|---|
| Slack・Notion・GitHub・Web だけ | **クラウドのルーティン**（既定） |
| Mac の中のファイル（kb、`~/.claude` の記録、ローカルの worktree など） | Mac の launchd |
| claude.ai に繋いでいない MCP（ローカルで起動する MCP サーバー） | Mac の launchd |
| ローカルでしか認証していない CLI（社内 VPN の中、gcloud など） | Mac の launchd |

クラウドを優先するのは、Mac が閉じていても動き、実行の記録が claude.ai に残るため。
launchd は Mac がスリープ中なら起きたときにまとめて 1 回走るだけなので、時刻どおりには届かない。

## クラウドのルーティン

`schedule` スキルで作る。リポジトリは `KokiKono/dotfiles`（このスキルの本体がある public リポジトリ）を指定し、
プロンプトは次の形にする。スキルの手順はリポジトリから読ませ、追跡できない値（ID 類）はプロンプトに直接書く。

```
定期レポートのルーティンです。このセッションの外の文脈はありません。

1. home/dot_claude/skills/report-my-channel/SKILL.md を読み、`run` として手順に従ってください
2. 設定（~/.claude/report-my-channel.local.json の代わり）:
   - slack_channel_id: <値>
   - database_url: <値>
   - data_source_url: <値>
   - dry_run: false
3. 報告の依頼:
   <依頼の文面。期間・対象・数え方まで、今回決めた基準をすべて書く>
   頻度: <毎朝 9 時 など。Slack の末尾の「🔁」行に使う>
```

作ったら、ルーティンの URL と次に走る時刻をユーザーに伝える。初回は `RemoteTrigger` の `run` で
1 回走らせ、`list_runs` → `get_run_log` で Slack と Notion まで届いたか確かめるとよい
（connector の権限が足りないと、ここで初めて分かる）。

## Mac の launchd

`scripts/local-routine.sh` を使う。ルーティンの定義は `~/.claude/report-my-channel/routines/<slug>.md`
（追跡外。依頼の文面に社内の固有名詞が入るため）に置き、スクリプトがそれを `claude -p` に渡す。

1. 定義ファイルを書く。frontmatter の `allowed_tools` には、スクリプトの `DEFAULT_TOOLS` に無いツールだけを
   コンマ区切りで書く

   ```markdown
   ---
   allowed_tools: Bash(ls:*),mcp__○○__△△
   ---
   <依頼の文面。クラウドのプロンプトの 3. と同じ粒度で書く>
   頻度: 平日 18 時
   ```

2. 登録する。時刻は `HH:MM` のコンマ区切りで複数書ける。曜日は 0（日）〜 6（土）のコンマ区切りで、省けば毎日

   ```bash
   ~/.claude/skills/report-my-channel/scripts/local-routine.sh install <slug> 09:00,13:00,17:00 1,2,3,4,5
   ```

   launchd は祝日を知らないので、平日指定でも祝日に走る

3. 1 回走らせて確かめる: `local-routine.sh run <slug>`。ログは `~/Library/Logs/report-my-channel-<slug>.log`

`local-routine.sh list` で登録済みを、`uninstall <slug>` で解除する。

`claude -p` は権限の確認を出せないので、`allowed_tools` に無いツールを使おうとした回は途中で止まる。
1 回目の `run` のログで、拒否されたツールが無いか見ること。

## 一覧（`routines`）

- クラウド: `RemoteTrigger` の `list` から、プロンプトに `report-my-channel` を含むものを出す
- Mac: `local-routine.sh list`

止める・頻度を変えるときも同じ置き場で行う（クラウドは `RemoteTrigger` の `update`、Mac は `install` のやり直し）。
