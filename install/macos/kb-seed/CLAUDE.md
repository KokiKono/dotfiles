# kb

issue をまたいで使うナレッジとスクリプトの置き場。hello-run が各セッションディレクトリに
`kb` という名前で symlink を張るので、作業中は `kb/` で参照できる。

## 構成

```
kb/
├── CLAUDE.md
└── issues/
    ├── <repo>-<issue番号>/   issue ごとのディレクトリ
    │   └── README.md        hello-run が雛形から作る
    └── scratch-<slug>/      issue を起票していない作業（hello-run --scratch）
```

- `README.md` のリンク・概要・進捗は、作業しながら埋めていく
- `README.md` 以外の構成は自由。調査に使ったスクリプト、SQL、メモなどを issue に合わせて置く

## 規約

- git を操作しない。10 分ごとに launchd が全変更をコミットして push する（`~/.config/kb/autosave.sh`）
- 自分の issue のディレクトリ以外は読むだけにする。他のセッションが並行して書いている
- 過去の issue のスクリプトを使い回すときは、自分の issue のディレクトリにコピーしてから直す
- 書き始める前に、関係しそうな過去の issue を探す（`grep -ril <キーワード> issues/`）
- 秘密情報（トークン、パスワード、個人情報を含むダンプ）を置かない。git の履歴に残る
- 複数の issue で繰り返し使うスクリプトに気づいたら、ユーザーに伝える。共通の置き場に切り出すかはユーザーが決める
