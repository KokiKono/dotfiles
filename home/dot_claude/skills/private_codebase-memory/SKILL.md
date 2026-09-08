---
name: codebase-memory
description: コードベースの知識グラフ（codebase-memory MCP）で構造を照会するときの作法。呼び出し元・呼び出し先の追跡、変更の影響範囲、デッドコードや fan-in/fan-out の洗い出し、サービス間の呼び出し関係、Cypher（query_graph）の書き方、grep とどちらを使うかの判断に使う。「この関数を直すと何が壊れるか」「誰が呼んでいるか」「この機能はどこに実装されているか」のような構造の問いには、grep で探し始める前にこれを読む。
---

# Codebase Memory — 知識グラフの使い方

構造の問いをグラフに投げると、精密な答えが ~500 トークンで返る。同じことを grep で確かめようとすると
候補ファイルを読み下すことになり ~80K トークンかかる。**構造の問いはグラフ、文字列の問いは grep** が基本線。

「構造の問い」とは、呼び出し関係・依存・定義位置・影響範囲のように**コードのつながり**を辿る問い。
「文字列の問い」とは、特定のリテラル・コメント・設定値のように**書かれている文字**を探す問い。
後者はグラフに載っていないので `search_code` か Grep を使う。

## どのツールを呼ぶか

| 問い | ツール呼び出し |
|----------|----------|
| 誰が X を呼んでいるか | `trace_path(direction="inbound")` |
| X は何を呼んでいるか | `trace_path(direction="outbound")` |
| 呼び出しの全体文脈 | `trace_path(direction="both")` |
| 名前パターンで探す | `search_graph(name_pattern="...")` |
| デッドコード | `search_graph(max_degree=0, exclude_entry_points=true)` |
| サービス間のエッジ | `query_graph`（Cypher） |
| ローカル変更の影響範囲 | `detect_changes()` |
| リスク分類付きの追跡 | `trace_path(risk_labels=true)` |
| 文字列を探す | `search_code` / Grep |

## 探索の手順

1. `list_projects` — インデックス済みか確認する。未登録なら先に `index_repository`。インデックスが無いまま
   照会すると空振りするだけで、グラフが無いのか該当が無いのかが区別できない。
2. `search_graph(label="Function", name_pattern=".*Pattern.*")` — 対象を見つける。
3. `get_code_snippet(qualified_name="project.path.FuncName")` — 実装を読む。

## 追跡の手順

1. `search_graph(name_pattern=".*FuncName.*")` — 正確な名前を確定させる。`trace_path` は完全一致しか受けない。
2. `trace_path(function_name="FuncName", direction="both", depth=3)` — 辿る。
3. `detect_changes()` — git diff を影響シンボルに対応づける。

## 品質の観点

- デッドコード: `search_graph(max_degree=0, exclude_entry_points=true)`
- fan-out 過多（責務の膨張）: `search_graph(min_degree=10, relationship="CALLS", direction="outbound")`
- fan-in 過多（変更が波及する要所）: `search_graph(min_degree=10, relationship="CALLS", direction="inbound")`

いずれも「数字が大きい＝悪い」ではない。エントリポイントやユーティリティは当然 fan-in が高い。
候補を出したあとに `get_code_snippet` で中身を見て判断する。

## つまずきやすい点

1. `search_graph(relationship="HTTP_CALLS")` はノードを次数で絞るだけで、エッジそのものは返さない。
   実際の呼び出し関係を見たいなら `query_graph` に Cypher を投げる。
2. `query_graph` は 200 行で打ち切られる。数を数えたいときは `search_graph` の degree フィルタを使う。
3. `direction="outbound"` だけではサービスを越えた呼び出し元を取りこぼす。影響範囲を見るなら `"both"`。
4. 結果は既定で 1 ページ 10 件。`has_more` を見て `offset` で続きを取る。取り切らずに「該当なし」と結論づけない。

Cypher の書き方・エッジ種別の一覧と使い分け・ツール一覧は
[`references/graph-query.md`](references/graph-query.md) にある。`query_graph` を書くときや、
辿ったのに呼び出し元が見つからないとき（別種のエッジに載っている可能性）に読む。
