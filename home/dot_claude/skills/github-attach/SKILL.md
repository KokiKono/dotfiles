---
name: github-attach
description: GitHub の Issue / PR の本文やコメントに、ローカルの画像・動画（スクリーンショット、GIF、録画）を gh CLI 標準の `--attach` フラグで添付する。「PR にスクショを添付して」「この画像を Issue に貼って」「動画をコメントに付けて」「before/after を PR に載せて」など、GitHub に画像や動画を載せる話が出たら必ずこのスキルを使う。GitHub Releases・リポジトリへの画像コミット・Gist・外部の画像ホスティングで代用しようとしている場面でも、先にこのスキルを読むこと。3 幅のスクショ撮影から行うなら pr-screenshot スキルを使う（アップロード部分はこのスキルと同じ方式）。
---

# GitHub に画像・動画を添付する

gh CLI v2.99.0 以降は `gh issue create/edit/comment` と `gh pr create/edit/comment` に
`--attach` がある。ブラウザで画像をドラッグしたときと同じ `github.com/user-attachments/assets/...`
にアップロードし、本文中の参照をその URL に書き換える。**添付はこれ 1 本で行う。**

## 使わない手段と理由

- **GitHub Releases（`gh release create` / `gh release upload`、拡張の `--release`）**:
  画像置き場のためだけにタグとリリースが残り、リリース一覧や通知を汚す。後から消す手間も増える。
- **リポジトリへの画像コミット / Gist / 外部ホスティング**: 差分や履歴に画像が混ざる、
  公開範囲がリポジトリと食い違う、リンク切れが起きる。
- **gh-attach 拡張 + playwright のブラウザログイン**: 標準の `--attach` が出る前の回避策。もう要らない。

`--attach` が失敗しても、上の手段に黙って切り替えない。エラーをそのまま見せてユーザーに相談する。

## 前提の確認

```bash
gh --version          # 2.99.0 未満なら brew upgrade gh を提案して止まる
```

- 添付先リポジトリへの書き込み権限が要る。GitHub Enterprise Server は対象外。
- 形式: PNG / JPEG / GIF / WebP / SVG / MP4 / MOV / WebM。
- サイズ: 画像・GIF は 10MB まで。動画は Free プラン 10MB、有料プラン 100MB まで。
- 1 コマンドで 50 ファイルまで。

## 書き方

### 末尾に足すだけでよいとき

```bash
gh pr comment <番号> --attach './after.png#修正後のログイン画面'
gh pr edit <番号> --attach ./before.png --attach ./after.png   # 本文は保ったまま末尾に追記
```

`#` の後ろが alt テキスト。省くとファイル名になる。動画には alt を付けられない。

### 本文の決まった位置に置きたいとき

本文ファイルにローカルパスを **Markdown の画像記法** で書き、同じファイルを `--attach` にも渡す。

```markdown
| 修正前 | 修正後 |
| --- | --- |
| ![修正前](./before.png) | ![修正後](./after.png) |
```

```bash
gh pr edit <番号> --body-file body.md --attach ./before.png --attach ./after.png
```

実際に投稿して確かめた挙動（gh 2.102.1）:

- `![alt](./a.png)`・`![alt](a.png)`・`![alt](/abs/path/a.png)` はどれも置換される。
  `./` の有無は `--attach` 側と揃っていなくてよい。本文ファイルの中では `~` が展開されないので、
  ホーム配下のファイルは展開済みの絶対パスで書く。
- **`<img src="./a.png">` は置換されない。** パスがそのまま残って画像が壊れ、
  さらに同じ画像が「参照されていない添付」として末尾にもう 1 枚足される。
  幅を指定したいなどで HTML を使いたくなっても、本文中では Markdown 記法にする。
- 本文が参照していない添付は、指定順に本文末尾へ足される。
- 本文中の既存の `user-attachments` URL はそのまま残る。

### 既存の PR 本文に追記するとき

`--body-file` は本文を丸ごと置き換える。既存の本文を取ってから追記して渡す。

```bash
gh pr view <番号> --json body -q .body > body.md
# body.md の適切な位置にセクションを足す（既存の記述は消さない）
gh pr edit <番号> --body-file body.md --attach ./shot.png
```

## 投稿後の確認

```bash
gh pr view <番号> --json body -q .body | grep -nE '\]\((\.|/)|src="(\.|/)'   # 何も出なければ OK
```

ローカルパスが残っていたら置換に失敗している。一部だけ失敗したときは、成功した分で更新したうえで
非 0 で終わるので、終了コードも見る。最後に PR / Issue の URL をユーザーに伝える。

## コメントへの添付について

PR / Issue へのコメント（`gh pr comment` / `gh issue comment`）は、投稿前に本文案と添付するファイルの
一覧をユーザーに見せ、承認を得てから実行する。本文の更新（`gh pr edit`）も、ユーザーが頼んだ範囲を
超えて書き換えない。
