# Codebase Memory — グラフ照会リファレンス

SKILL.md 本文で足りないとき（Cypher を書く / エッジ種別を知りたい / どのツールがあるか確認したい）に読む。

## 目次
- [MCP ツール一覧](#mcp-ツール一覧)
- [ノードとエッジの種別](#ノードとエッジの種別)
- [Cypher の例](#cypher-の例)

## MCP ツール一覧

インデックス管理: `index_repository`, `index_status`, `list_projects`, `delete_project`
照会: `search_graph`, `search_code`, `trace_path`, `query_graph`, `get_code_snippet`, `get_architecture`, `get_graph_schema`
差分・付随情報: `detect_changes`, `manage_adr`, `ingest_traces`

各ツールの引数はスキーマが正で、この一覧は「何ができるか」の見取り図。増減しうるので、実際の引数は
`get_graph_schema` とツールスキーマを確認する。

## ノードとエッジの種別

エッジ:
`CALLS`, `HTTP_CALLS`, `ASYNC_CALLS`, `IMPORTS`, `DEFINES`, `DEFINES_METHOD`,
`HANDLES`, `IMPLEMENTS`, `OVERRIDE`, `USAGE`, `FILE_CHANGES_WITH`,
`CONTAINS_FILE`, `CONTAINS_FOLDER`, `CONTAINS_PACKAGE`

使い分けの目安:

- サービス境界を越える呼び出しは `CALLS` ではなく `HTTP_CALLS` / `ASYNC_CALLS` に載る。「呼び出し元が見つからない」ときは
  こちらを見る。
- `FILE_CHANGES_WITH` は git 履歴由来の共変更。静的な依存が無いのに一緒に直る組（設定とその読み手など）を拾える。
- `IMPLEMENTS` / `OVERRIDE` があるコードでは、`CALLS` だけを辿ると実装側に届かない。

対象リポジトリで実際にどの種別が張られているかは `get_graph_schema` で確認するのが確実（言語・indexer の対応状況で変わる）。

## Cypher の例

`query_graph` に渡す。200 行で打ち切られるので、件数を数えたいときは `search_graph` の degree フィルタを使う。

サービス間の HTTP 呼び出しを、確度付きで一覧する:
```cypher
MATCH (a)-[r:HTTP_CALLS]->(b)
RETURN a.name, b.name, r.url_path, r.confidence LIMIT 20
```

名前パターンで関数を引く（`search_graph` で足りるが、他の条件と組みたいとき）:
```cypher
MATCH (f:Function) WHERE f.name =~ '.*Handler.*'
RETURN f.name, f.file_path
```

特定関数の呼び出し先:
```cypher
MATCH (a)-[r:CALLS]->(b) WHERE a.name = 'main' RETURN b.name
```

同じファイルに同居している定義を数える（ファイルの責務が膨らんでいないか）:
```cypher
MATCH (file)-[:CONTAINS_FILE|DEFINES]->(f:Function)
RETURN file.path, count(f) AS n ORDER BY n DESC LIMIT 20
```
