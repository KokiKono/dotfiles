---
name: dev-server
description: herdr の dev 専用 tab に pane を分けて、ローカルの dev サーバーを起動・再利用・停止・再起動する。「動作確認したい」「dev サーバー立てて」「localhost で見たい」「〇〇のサーバー止めて/再起動して」等で使う。スクショやブラウザ確認の前段でサーバーが要るときも、明示的に言われなくてもこのスキルで起動してよい。HERDR_ENV=1 が前提。
---

# dev サーバーを herdr の1つの tab で管理する

dev サーバーが「どこで動いているか分からない」状態を作らないためのスキル。**この workspace（= worktree）につき `dev` という label の tab を1つだけ持ち、アプリごとに pane を分ける。**tab を増やさないことがこのスキルの本体で、それ以外は普通の herdr 操作。

ここに書くのは毎回判断が要る部分だけ。herdr CLI の詳細は `herdr tab` / `herdr pane` を実行して確認する。

## 0. 前提とコマンドの決定

```bash
test "${HERDR_ENV:-}" = 1
```

失敗したら「herdr の外なので起動先の pane を用意できない」と伝えて、ユーザーに手動起動を依頼して止まる。

次に対象アプリの**起動コマンドとポート**を決める。

- `references/<リポジトリ名>.md` があれば**それを正として引く**。monorepo はスクリプト名が `dev` / `start` で揺れ、ポートもアプリ固有なので、表がある限り推測しない
- 無ければ `package.json` の `dev` / `start` から推定し、**推定したコマンドとポートをユーザーに見せてから**実行する。間違ったコマンドを常駐させると、気づくのは数分後になる

### リポジトリ固有の表について

`references/` に置く表は**この dotfiles リポジトリでは追跡していない**（public なので、
業務リポジトリのアプリ名・内部 URL・環境変数名を置けない）。`chezmoi apply` は
`references/` に触らないので、手で置いたファイルはそのまま残る。

新しいリポジトリで表を起こすときは、少なくとも次を書く。これが無いと毎回ポートを探し直す。

- app ごとの起動コマンドとポート（`dev` / `start` の揺れを含む）
- ready 行の実測値（`wait-output` の `--regex` をこれに合わせる）
- 起動の前提（必要な env ファイル、`APP_ENV` のような必須変数、初回の生成処理）
- ポートを共有してしまうもの（Storybook など）

## 1. まず「もう動いていないか」を見る

Next も Expo も起動は遅い。立て直さないことが一番効く。

```bash
lsof -ti tcp:<port>
lsof -p <pid> -a -d cwd -Fn   # そのプロセスの cwd
```

- cwd が**今の worktree 配下** → 再利用する。URL を報告して終わり
- cwd が**別の worktree / 別リポジトリ** → **止まってユーザーに聞く。** kill も別ポートでの起動もしない。別ブランチの画面を本物だと思って確認してしまうのが、このスキルで一番避けたい失敗。どの worktree のサーバーがそのポートを持っているかを添えて判断を仰ぐ
- ポートが固定でないもの（portless のようなプロキシ配下）は `~/.portless/routes.json` の hostname / port を見る。`portless list` は PATH に無い（`./node_modules/.bin/portless`）うえ、routes.json に載っているサーバーを `No active routes.` と言うことがあるので当てにしない

## 2. dev tab は1つだけ

```bash
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
```

`label` が `dev` の tab を探す。無ければ作る:

```bash
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label dev --cwd "$PWD" --no-focus
```

`.result.tab.tab_id` と `.result.root_pane.pane_id` をレスポンスから読む（ID は必ず JSON から。並び順や例から推測しない）。

**2つ目以降のアプリでも新しい tab は作らない。** tab が増えた時点で、このスキルが解こうとしている「どこで何が動いているか分からない」に戻る。

## 3. アプリごとに pane

```bash
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
```

`tab_id` が dev tab のものに絞る。pane の `label` にアプリ名を入れてあるので、そこで既存の pane を突き止められる。

- dev tab が空（作りたて）なら root pane をそのまま使う
- 2つ目以降は既存 pane の形を見てから分割する。横長なら `right`、縦長なら `down`。同じ方向に続けて割ると読めない幅になる

```bash
herdr pane layout --pane <既存pane>
herdr pane split <既存pane> --direction right --cwd "$PWD" --no-focus
herdr pane rename <新pane> <アプリ名>
```

rename は飾りではなく、次回この pane を見つけるための唯一の手掛かりなので必ず付ける。

pane が4つ以上になると1枚あたりが読めない大きさになる。3つを超えるときは、今使っていないアプリを止めてその pane を使い回してよいかユーザーに聞く。

## 4. 起動して ready を待つ

```bash
herdr pane run <pane> "<起動コマンド>"
herdr pane wait-output <pane> --regex "(?i)ready in|waiting on|started server|EADDRINUSE|error:|command not found" --timeout 180000
```

- **成功と失敗の両方を1つの正規表現に入れる。** 成功語だけ待つと、クラッシュしたときに無言でタイムアウトまで待つことになり、ユーザーから見ると「固まった」ようにしか見えない
- **`(?i)` を付ける（Rust 正規表現）。** Expo は `Web is waiting on http://localhost:3004` と小文字で出す。`Waiting on` で待つと起動しているのにタイムアウトする
- マッチは ready の証明にはならない（Expo は Web より先に `Metro waiting on` を出す）。**最後は `curl -sI -o /dev/null -w "%{http_code}" http://localhost:<port>/` で実際に応答することを確かめる。**リダイレクト（307 等）でも応答していれば起動している

失敗側にマッチしたらログを読んで原因を要約して報告する:

```bash
herdr pane read <pane> --source recent-unwrapped --lines 120
```

Expo は QR コードを描くので、この出力をそのまま貼らない。`grep` で必要な行だけ取り出す。

典型は env 未設定・依存未インストール・ポート衝突。自分で直せる範囲（`.env.local.example` のコピー等）はリファレンスに書いてあれば実行してよいが、認証情報が要るものはユーザーに渡す。

成功したら URL を報告する。

## 5. 停止・再起動

```bash
herdr pane send-keys <pane> ctrl+c
lsof -ti tcp:<port>    # 空になるまで確認
```

Metro / Expo は1回の Ctrl-C で落ちないことがある。数秒待って残っていたらもう一度送る。「送ったから止まった」とは見なさない。

再起動は**同じ pane で** `herdr pane run <pane> "<起動コマンド>"`。pane を作り直すとレイアウトと pane 名が失われる。

- **pane / tab を close するのはユーザーが明示的に頼んだときだけ。** 自分が作った dev tab でも、他のアプリがまだ動いている
- portless のプロキシ（`~/.portless/`）のような共有インフラは止めない。他の worktree も使っている

## 6. 全体を通して

- herdr コマンドには `--no-focus`。ユーザーの視線は今の pane に置いたままにする
- サーバーを立てるところまでがこのスキルの仕事。撮影は `pr-screenshot`、ブラウザ操作は chrome-devtools に渡す
