---
name: pr-screenshot
description: ローカルの dev サーバーでページを3幅（375/768/1440）撮影し、gh attach でアップロードして PR 本文に「## 実表示」の表として追加する。「スクショをPRに貼って」「実表示を本文に追加して」「UI の見た目をPRに載せて」等、PR に画面キャプチャを載せたいときに使う。UI 変更の PR を作る流れで「見た目を見せたい」という話が出たら、明示的にスクショと言われなくても提案してよい。
---

# PR にスクリーンショットを貼る

引数: `/pr-screenshot [PR番号] [URLまたはパス] [ポート]` — 全て省略可。

撮影とアップロードの手順は `scripts/` に落としてある。ここに書くのは**引数の決め方・投稿する本文の作り方・確認の仕方**、つまり毎回判断が要る部分だけ。

## 0. 引数の解決

- **PR番号**: 引数になければ `gh pr view --json number,url` で現在のブランチの PR を使う。それも無ければユーザーに聞く。
- **URL**: 引数がパスだけなら `http://localhost:<ポート>/<パス>`。URL もパスも無ければ、PR の差分から対象ページを推定して**ユーザーに確認してから**撮る。推定を確認なしで撮ると、無関係なページの画像が PR に残る。
- **ポート**: 既定 3000。
- **dev サーバーはユーザーが起動する。** 自分で起動しない。撮影スクリプトが HTTP 200 を確認できなければ、起動を依頼して止まる。

## 1. 撮影

```bash
scripts/capture-3widths.sh "<URL>"     # $TMPDIR/w375.png, w768.png, w1440.png
```

スクリプトが chrome-devtools CLI でタブを選び直し、3幅を撮り、開いた URL と `innerWidth` を検算する（MCP を使わない理由・CLI 固有の落とし穴はスクリプト内のコメントに書いてある）。

撮れた3枚は **Read ツールで目視する。** 崩れ・ローディング途中・空白のまま撮れている、といった失敗は検算では捕まらない。

## 2. アップロード

```bash
scripts/ensure-gh-attach-patch.sh      # 拡張のローカル修正2件を検査・再適用（冪等）
gh attach --repo <owner/repo> --issue <PR番号> \
  --image "$TMPDIR/w375.png" --image "$TMPDIR/w768.png" --image "$TMPDIR/w1440.png" \
  --url-only --session gh-attach --keep-session
```

- `--session` は必須。無いと macOS の bash 3.2 が `pw_open_extra[@]: unbound variable` を出す。
- `--release` は**使わない**。リポジトリにリリースタグを作ってしまう。
- 前提として `npm install -g @playwright/cli`。
- 未ログインなら `playwright-cli --session gh-attach open --persistent --headed https://github.com/login` を実行し、**ユーザーにログインしてもらってから**続行する。
- `ensure-gh-attach-patch.sh` が「自動適用できません」と言う場合は拡張の実装が変わっている。拡張本体を読んで手で当て、スクリプトの検出条件も直す（`gh extension upgrade` のたびに修正は消えるので、都度当て直す前提で作ってある）。
- Bash が E2BIG で全滅する場合は `dangerouslyDisableSandbox: true` で実行する。

## 3. PR 本文に追記

既存の本文を `gh pr view <PR番号> --json body -q .body` で取得し、**消さずに**「変更内容」と「確認事項」の間へ次のセクションを挿入して `gh pr edit <PR番号> --body-file <file>`。

```markdown
## 実表示

<ページ名>を3つの幅で表示したものです。クリックで拡大できます。

| モバイル 375px | タブレット 768px | デスクトップ 1440px |
| --- | --- | --- |
| <img alt="モバイル 375px" src="URL1" /> | <img alt="タブレット 768px" src="URL2" /> | <img alt="デスクトップ 1440px" src="URL3" /> |
```

`width` 属性は付けない（3列レイアウトが崩れる）。列ヘッダーの3列構成を保つ。

## 4. 検証して報告

投稿しただけでは画像が壊れていても気づけないので、ログイン済みセッションで本文を開いて実際に描画されたか確かめる。

```bash
playwright-cli --session gh-attach goto "<PR URL>"
playwright-cli --session gh-attach eval "() => { const t=document.querySelector('.markdown-body table'); return JSON.stringify({headers:[...t.querySelectorAll('th')].map(e=>e.innerText), imgs:[...t.querySelectorAll('td img')].map(i=>i.naturalWidth)}); }"
```

3列のヘッダーと画像3枚（`naturalWidth` が 375/768/1440）を確認できたら完了を報告する。

撮影中に気づいた**この PR と無関係な表示崩れ**は本文に書かない（レビュー対象が広がる）。報告で伝えて扱いを聞く。

self-review はこのスキルでは実行しない（ユーザーの目検後、指示があってから）。
