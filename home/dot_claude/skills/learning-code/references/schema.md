# skills.json のスキーマ

実体は `~/.learning/skills.json`（`LEARNING_HOME` で差し替え可）。**このファイルは dotfiles で追跡しない** —
個人の学習データで、リポジトリは public。追跡するのは雛形 `references/skills.template.json` だけ。

読み書きは必ず `scripts/skills-db.sh` 経由で行う。直接 Edit すると昇降格のルールを飛ばしてしまう。

```json
{
  "version": 1,
  "profile": {
    "baseline": "基本情報技術者 / Web 業界 10 年",
    "known_stack": ["react", "typescript", "laravel", "mysql"]
  },
  "updated_at": "2026-10-05",
  "domains": {
    "ruby": {
      "kind": "language",
      "level": "junior",
      "assessed_at": "2026-10-05",
      "items": [
        {
          "topic": "ブロックと yield",
          "level": "junior",
          "last_judged": "senior",
          "last_tested": "2026-10-05",
          "note": "何が呼ばれるかは説明できたが Proc との return の違いに触れなかった",
          "source": "PR #123"
        }
      ]
    }
  }
}
```

## フィールド

| フィールド | 説明 |
|---|---|
| `domains.<name>.kind` | `language` / `framework` / `domain` のいずれか |
| `domains.<name>.level` | 項目レベルの中央値（低いほう寄り）。`skills-db.sh` が自動計算する |
| `items[].level` | 確定レベル。昇降格ルールを通した結果 |
| `items[].last_judged` | 直近の**生の**判定。昇格の「2 回連続」判定に使う |
| `items[].last_tested` | 最後に出題した日（`YYYY-MM-DD`）。`due` の起点 |
| `items[].note` | 判定の根拠 1 行。次回の深掘り位置になるので必ず書く |
| `items[].source` | `PR #123` / `initial` / `review` など、どこで測ったか |

## 昇降格のルール

`upsert` に渡すのは**その回の生の判定**で、確定レベルはスクリプトが決める。

- **初回**: 判定をそのまま確定レベルにする
- **昇格**: 同一 topic で **2 回連続**で上位判定が出たときだけ、**1 段階**上げる。
  1 回だけの上振れは `last_judged` に記録して確定レベルは据え置く（まぐれ当たりを弾く）
- **降格**: 1 回で **1 段階**下げる。説明できなくなっているなら即座に落とす
- **同判定**: 据え置き

## 再出題の間隔（`due`）

`last_tested` からの経過日数がこれを超えたら復習対象:

| レベル | 間隔 |
|---|---|
| `beginner` / `junior` | 7 日 |
| `senior` | 30 日 |
| `professional` | 90 日 |

定着していない項目ほど早く戻ってくる。間隔を変えるときは `skills-db.sh` の `interval` 定義を直す
（表はそのコピーなので一緒に更新する）。
