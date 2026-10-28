---
name: takt-order
description: GitHub issue を読んで、takt（AI エージェントのワークフローエンジン）に流すワークフローを選ぶか組み、kb に発注書・タスク文・YAML を残して実行コマンドを渡す。実行後は .takt/runs の結果を振り返り、選び方の経験則と再利用できるナレッジを kb に貯める。「takt で回したい」「この issue を takt に流して」「takt の WF 組んで」「takt に発注」「takt の結果を振り返って」などで使う。issue を AI に実装させる話で takt の名前が出たら、スキル名を言われなくても使うこと。
argument-hint: "[issue URL | 番号 | retro [run ディレクトリ]]"
---

# takt-order

issue を分析して takt のワークフロー（以下 WF）を決め、**実行はユーザーに任せる**。
このスキルが持つのは「どの WF で、何を足して流すか」の判断と、その判断を kb に残して次に活かす流れ。

置き場と書式は `references/kb.md`、WF の選び方は `references/design.md`、YAML の書き方と
検証済みの挙動は `references/authoring.md` にある。**該当する段階に入る前に読む。**

## 0. 準備とモード

```bash
TK=$(scripts/kb.sh)          # kb/takt のパスを出す。無ければ雛形から作る（冪等）
scripts/takt.sh --version    # takt を呼ぶときは常にこのラッパー経由
```

`takt` は mise の shim なので、node のバージョンが決まっていないディレクトリでは落ちる。
`scripts/takt.sh` はそのとき takt が入っている node を探して `mise exec` で呼び直す。

| 引数 | モード |
|---|---|
| issue の URL / 番号 | 発注（§1〜§5） |
| なし | セッションディレクトリの `.issue-url` があれば発注、無ければ issue を聞く |
| `retro` / `振り返り`（run ディレクトリ指定は任意） | 振り返り（§6） |

想定する起動場所は hello-run のセッションディレクトリ（`<root>/.sessions/issue-<N>/`）。
直下に repo ごとの worktree と `kb` の symlink がある。takt は **worktree の中で**実行する。

## 1. 材料を集める

1. issue: `gh issue view <url> --json title,body,labels,comments`。番号だけなら repo を確かめる
2. 発注 ID を決める: kb の issue ディレクトリと同じ `<repo>-<番号>`（`--scratch` なら `scratch-<slug>`）
3. 対象 repo: セッション直下の worktree のうち、変更が入るものを issue から判断する。
   **1 回の takt 実行は 1 repo**。複数 repo にまたがるなら repo ごとに発注を分ける
4. 過去の知見を探す（`references/kb.md` §探し方）
   - `$TK/playbook.md` は全文読む
   - `$TK/orders/*/order.md` と `<kb>/issues/*/` をキーワードで grep し、似た issue を拾う
   - `$TK/facets/knowledge/` の一覧を見て、対象 repo や領域に当たるものを拾う

対象 repo の CLAUDE.md / AGENTS.md は takt のエージェント（claude）が自分で読むので、
facet に写さない。写すと repo 側の更新に追従しなくなる。

## 2. issue を分析する

`references/design.md` §1 の観点で、種類・範囲・不確かさ・確かめ方・リスクを短く書き出す。
**判断に効いた事実だけ**を書く。issue 本文の要約を長く貼らない。

要件が足りず takt の plan が ABORT しそうなら、WF を組む前にユーザーへ質問して埋める。
takt に渡してから「要件不明」で止まるほうが高くつく。

## 3. WF を決める

`references/design.md` §2 の順で決める。

1. playbook に当たる型があれば、そこに書いた WF を第一候補にする
2. builtin をそのまま使う（`-w maintenance` など）
3. builtin のコアを呼ぶ薄い WF を組み、kb の知見を差し込む（大半はこれ）
4. step から自分で組む（調査を先に挟む、段階を減らすなど、流れ自体を変えたいとき）

3 と 4 の YAML は `$TK/orders/<ID>/workflow.yaml` に書く。
この issue 用に集めた知見は `$TK/orders/<ID>/knowledge.md` にまとめ、WF に差し込む。
既存 issue の調査メモを丸ごと渡さず、**今回の実装判断に要る事実だけ**を出典の path 付きで書く。

## 4. 検証する

```bash
scripts/takt.sh workflow doctor "$TK/orders/<ID>/workflow.yaml"
```

`Workflow OK` が出るまで直す。`Unused knowledge entry` の WARN は、`workflow_call` に
絶対パスで渡した facet をセクションマップにも残しているときに出るだけなので消してよい。
`takt prompt` は対話待ちで止まるので使わない。

## 5. 発注書を残してコマンドを渡す

`$TK/orders/<ID>/` に `order.md`（発注書）と `task.md`（takt に渡すタスク文）を書く。
書式は `references/kb.md` §発注書・§タスク文。

最後にユーザーへ次を示して終わる。**takt は実行しない。**

```bash
cd <セッション>/<repo>
# .takt/ を git に出さない（初回だけ。worktree 共通の exclude に足す）。
# takt が置く .takt/.gitignore は自分自身を除外しないので、それで判定する
git check-ignore -q .takt/.gitignore || echo '.takt/' >> "$(git rev-parse --git-common-dir)/info/exclude"
takt --pipeline --skip-git -w "$TK/orders/<ID>/workflow.yaml" -t "$(cat "$TK/orders/<ID>/task.md")"
```

- `$TK` は展開した絶対パスで書く（ユーザーのシェルには `$TK` が無い）
- builtin をそのまま使うときは `-w <名前>`
- `--pipeline --skip-git` は今のブランチのまま作業ツリーを書き換え、commit も push もしない。
  hello-run が切ったブランチをそのまま使うための指定。会話しながら進めたいなら
  `takt -w ...` で対話モードに入り「ここで実行」を選ぶ方法もある、と 1 行添える
- 所要の目安（default 系は agent 数が多く長い）を 1 行添える

## 6. 振り返り（retro）

対象の run を決める。指定が無ければ、セッション内の worktree の `.takt/runs/` から最新を選ぶ。
どの発注のものかは `meta.json` の `workflow` と `$TK/orders/*/order.md` の照合で決める。

1. `meta.json`（status・reason・iterations）、`trace.md`（step の順と往復）、`reports/` を読む
2. 実装結果を `git diff` で見る。レビューで何が指摘され、何回直したかを trace から拾う
3. order.md の「見立て」と突き合わせ、§結果 と §振り返り を書く（`references/kb.md` §振り返り）
4. 次に活かせることを、置き場ごとに提案する
   - `playbook.md` に足す 1 項目（issue の型 → WF → 結果）
   - `facets/knowledge/` に昇格する知見（2 回目に使った、または repo 共通と分かったもの）
   - `workflows/` に昇格する WF（同じ形で 2 回流した、または汎用と判断できたもの）

`orders/<ID>/` はこの発注の持ち物なので直接書く。`playbook.md`・`facets/`・`workflows/` は
他のセッションも読む共有の場所なので、**差分を見せて OK をもらってから**書く。

## やらないこと

- takt を実行しない（`takt run` / `takt add` / pipeline 実行のどれも）
- `~/.takt/` と worktree の `.takt/workflows` に書かない。自作の WF と facet は kb だけに置く
- kb で git を操作しない（kb は launchd の autosave が commit・push する）
- 秘密情報や個人情報を kb に書かない（git の履歴に残る）
