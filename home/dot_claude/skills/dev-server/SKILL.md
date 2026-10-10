---
name: dev-server
description: herdr の worktree ごとの dev タブで、ローカルの dev サーバーを起動・一覧・停止・再起動する。「動作確認したい」「dev サーバー立てて」「localhost で見たい」「〇〇のサーバー止めて/再起動して」等で使う。スクショやブラウザ確認の前段でサーバーが要るときも、明示的に言われなくてもこのスキルで起動してよい。HERDR_ENV=1 が前提。
---

# dev サーバーは `dev-server` CLI に任せる

タブの探索・pane の分割・ポートの割り当て・ready 待ちは、すべて `dev-server`
（`~/.config/zsh/dev-server.zsh`、ログインシェルで定義済み）が持っている。
**ここで herdr を直接叩かない。** 手順をなぞると判断がブレて、タブと pane が増える。

```bash
test "${HERDR_ENV:-}" = 1
```

失敗したら「herdr の外なので起動先の pane を用意できない」と伝えて、ユーザーに手動起動を
依頼して止まる。

## 使い方

**対象 worktree の中で**（`cd <worktree>/<repo>`）、`--json` を付けて叩く。

```bash
dev-server --json <app> [<app>...]   # 起動（既に動いていれば落として立て直す）
dev-server list --json               # 何がどのポートで動いているか
dev-server stop --json <app>...      # 止める（pane は残す。--close で閉じる）
dev-server restart --json <app>...   # start と同じ
```

引数なしで叩くと fzf が開く。**Claude からは必ずアプリ名を指定する**（対話を待って固まる）。

返る JSON:

```json
{"ok":true,"label":"dev-issue-123","tab":"w4:tE",
 "apps":[{"name":"○○","port":4001,"url":"http://localhost:4001","pane":"w4:p12","status":"started"}]}
```

`status` は `started` / `restarted` / `running` / `stopped` / `conflict` / `failed`。

## 判断が要るのはここだけ

- **`conflict`**: そのポートを別の worktree が握っていて、固定ポートなので逃げられない
  （Metro・Storybook・プロキシ配下など）。**kill も別ポートでの起動もしない。**
  `detail` に持ち主のパスが入っているので、それを添えてユーザーに判断を仰ぐ。
  別ブランチの画面を本物だと思って確認してしまうのが、ここで一番避けたい失敗。
- **`failed`**: `detail` と `herdr pane read <pane> --source recent-unwrapped --lines 120` で
  原因を要約して報告する。典型は env 未設定・依存未インストール。Expo は QR コードを
  描くので、この出力をそのまま貼らずに `grep` で必要な行だけ取り出す。
  認証情報が要るものはユーザーに渡す。
- **設定が無い**（exit 2 で `~/.config/dev-server/<repo>.json` が無いと言われた）:
  そのリポジトリの表をまだ起こしていない。雛形は `~/.config/dev-server/apps.example.json`。
  `package.json` から推定してよいが、**書き込む前に内容をユーザーに見せて確認を取る。**
  間違ったコマンドを常駐させると、気づくのは数分後になる。キーは次の通り。

  | key | 中身 |
  | --- | --- |
  | `name` | アプリ名（CLI に渡す名前であり pane の label） |
  | `cwd` | リポジトリルートからの相対。コマンドを打つ場所 |
  | `cmd` | **展開済みの起動コマンド。ポートは `{{port}}`。** package.json の script は `--port` が焼かれていて上書きできないので、script 名ではなく中身を書く |
  | `env` | コマンドの前に置く環境変数 |
  | `base_port` | ここから空きを探す |
  | `port_fixed` | ポートを動かせないなら `true`（衝突したら `conflict` になる） |
  | `ready_regex` | **実測した ready 行。** 大小は無視される |
  | `url` / `check_http` | 起動確認に使う URL（`{{port}}` 可） |

  **この表はリポジトリごとに1回書けば済む。** 書いたら次回からは CLI が全部やる。

## 範囲

サーバーを立てるところまでがこのスキルの仕事。撮影は `pr-screenshot`、ブラウザ操作は
chrome-devtools に渡す。`~/.portless/` のような共有インフラは止めない（他の worktree も使う）。
