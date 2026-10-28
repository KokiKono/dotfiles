# WF YAML の書き方

スキーマ全体はここに写さない（takt の版で変わる）。正確な定義は入っている takt から読む。

```bash
ROOT=$(scripts/takt.sh --root)
$ROOT/builtins/skill/references/yaml-schema.md   # YAML の構造
$ROOT/builtins/ja/facets/knowledge/takt.md       # エンジンの動き（3 フェーズ、rule 評価）
$ROOT/builtins/ja/workflows/                     # builtin WF。書き方の手本
$ROOT/builtins/ja/facets/                        # builtin facet。名前だけで参照できる
$ROOT/builtins/ja/*_STYLE_GUIDE.md               # facet を自作するときの書き方
```

## takt v0.71 で確かめた挙動

どれも `takt workflow doctor` と mock プロバイダーでの実行で確認したもの。

- `-w` には名前だけでなく **YAML のパス**を渡せる。`~/.takt/` に置かなくても動く
- step の `persona` / `policy` / `knowledge` / `instruction` に書いた**素の名前**は builtin の facet に解決される
- WF 冒頭のセクションマップ（`knowledge: {名前: パス}`）のパスは **YAML ファイルからの相対パス**で解決される
- `workflow_call` の `args` に渡す facet は、呼び出し側のセクションマップの名前も相対パスも `~` も**解決されない**。
  **絶対パスなら通り**、プロンプトにも入る
- `args` の一覧は既定値を**置き換える**（足し算ではない）。builtin の一覧を写してから足す
- `--pipeline --skip-git` は今のブランチ・作業ツリーで動き、commit も push もしない。
  結果は `.takt/runs/<日時>-<slug>/` に `meta.json`・`trace.md`・`reports/`・`context/`・`workflow-bundle/` として残る
- `workflow-bundle/` には実行時の WF と facet の写しが入る。振り返りで「何を渡したか」はここで分かる
- `takt prompt` は対話待ちで止まる。非対話では使えない
- どの rule にも当たらないと `rule_no_match` で ABORT する。condition は step の出力から判定できる言葉にする

## 薄い WF（builtin のコア + kb の知見）

1. 元にする builtin を写す: `cp "$ROOT/builtins/ja/workflows/maintenance.yaml" "$TK/orders/<ID>/workflow.yaml"`
2. `name` を発注 ID に、`description` を「何に何を足したか」に変える
3. `args` の `*_knowledge` に kb の facet を**絶対パス**で足す
   - 写した builtin が渡していない引数（`default` は `review_knowledge` しか渡していない、など）に足すときは、
     コアの既定値を `$ROOT/builtins/ja/workflows/development-core.yaml`（mini 系は `mini-core.yaml`）の
     `subworkflow.params` から写してから足す。写さずに足すと既定の facet が外れる
4. 差し込む先の目安: 計画が変わる知見は `plan_knowledge`、実装の落とし穴は `development_knowledge`、
   レビューで見てほしい点は `review_knowledge`。迷ったら 3 つ全部に入れる

```yaml
name: <repo>-<番号>
description: maintenance に、○○画面の状態管理の落とし穴と過去 issue の調査結果を足す
max_steps: 51
initial_step: develop
steps:
  - name: develop
    kind: workflow_call
    call: development-core
    args:
      # ...maintenance.yaml の args をそのまま...
      plan_knowledge:
        - architecture
        - task-decomposition
        - existing-system
        - /Users/<user>/git_clone/local/kb/takt/orders/<ID>/knowledge.md
        - /Users/<user>/git_clone/local/kb/takt/facets/knowledge/<repo>.md
      # development_knowledge / review_knowledge も同様に足す
    rules:
      - condition: COMPLETE
        next: COMPLETE
      - condition: ABORT
        next: ABORT
```

`max_steps` などほかの値は、理由があるときだけ変える。変えたら order.md に理由を書く。

## 自分で組む

builtin の step を手本にして、`steps` を直接書く。

```yaml
name: <ID>
description: <何をする流れか>
max_steps: 20
initial_step: investigate
knowledge:
  issue-notes: ./knowledge.md                       # YAML からの相対パス
  repo: ../../facets/knowledge/<repo>.md
steps:
  - name: investigate
    edit: false                                      # 全 step で必須
    persona: planner
    policy: [design-planning]
    knowledge: [architecture, issue-notes, repo]
    instruction: |
      原因を特定し、直す場所と直し方の候補を挙げてください。コードは変更しないでください。
    output_contracts:
      report:
        - name: investigation.md
          format: |
            # 調査結果
            ## 原因
            ## 直す場所
            ## 方針
    rules:
      - condition: 原因と直す場所を特定できた
        next: implement
      - condition: 原因を特定できない
        next: ABORT
  - name: implement
    edit: true
    capabilities: edit
    persona: coder
    policy: [coding, testing]
    knowledge: [architecture, issue-notes, repo]
    instruction: implement
    rules:
      - condition: 実装が完了した
        next: review
      - condition: 実装を進行できない
        next: ABORT
  - name: review
    edit: false
    persona: coding-reviewer
    policy: [review, coding]
    knowledge: [architecture, issue-notes, repo]
    instruction: simple-review-coding
    pass_previous_response: false
    rules:
      - condition: approved
        next: COMPLETE
      - condition: needs_fix
        next: implement
```

- 前の step の report は instruction の中で `{report:investigation.md}` と書けば展開される
- 修正ループには上限を置く。`loop_monitors` か `max_steps` で止める
- `quality_gates` の `type: command` は `~/.takt/config.yaml` の
  `workflow_command_gates.custom_scripts: true` が無いと使えない（既定は無効）。
  テストのコマンドは文字列の gate か task.md の「確かめ方」に書く

## facet を自作するとき

kb の `facets/<kind>/` に置く。書き方は `$ROOT/builtins/ja/*_STYLE_GUIDE.md` に従う。
knowledge は「事実と、なぜそうなっているか」、policy は「守ること」を書き、混ぜない。
