# kb/takt の置き場と書式

## 構成

```
<kb>/takt/
├── README.md              索引。自作 WF と facet の一覧（1 行説明と向く issue）
├── playbook.md            WF の選び方の経験則。振り返りで育てる
├── workflows/<名前>.yaml  再利用する WF（orders から昇格したもの）
├── facets/
│   ├── knowledge/         <repo>.md（repo 固有の落とし穴）、<領域>.md（領域の知見）
│   ├── policies/
│   ├── instructions/
│   ├── personas/
│   └── output-contracts/
└── orders/<発注ID>/       1 発注 1 ディレクトリ。発注 ID は <repo>-<番号> か scratch-<slug>
    ├── order.md           発注書（分析・選んだ WF と理由・コマンド・結果・振り返り）
    ├── task.md            takt に -t で渡すタスク文
    ├── workflow.yaml      組んだときだけ
    └── knowledge.md       この発注のために集めた知見。WF に差し込む
```

kb の場所は `scripts/kb.sh` が決める（`./kb` → `$HELLO_RUN_KB` → `~/git_clone/local/kb`）。
issue ごとの作業メモ（`<kb>/issues/<repo>-<番号>/`）は hello-run の持ち物で、ここでは読むだけにする。

## 探し方

発注のたびに次を見る。結果は order.md の「参照した知見」に path で残す。

```bash
cat "$TK/playbook.md"
ls "$TK/facets/knowledge" "$TK/workflows"
grep -ril '<キーワード>' "$TK/orders" "$TK/../issues" | head -20
```

キーワードは issue に出てくる画面名・モデル名・API のパス・エラーメッセージ。
1 語で当たらなければ言い換えを 2〜3 個試す。当たった issue の README は進捗と結論の節から読む。

## 発注書（order.md）

```markdown
# <発注ID>: <issue タイトル>

- issue: <URL>
- 対象 repo: <repo>（worktree: <パス>）
- 発注日: YYYY-MM-DD

## 分析
- 種類:
- 範囲:
- 不確かさ:
- 確かめ方:
- リスク:

## 参照した知見
- <path>: <何が分かったか 1 行>

## WF
- 使う WF: <builtin 名 | orders/<ID>/workflow.yaml>
- 選んだ理由: <playbook のどの項目か、または分析のどれが効いたか>
- 差し込んだ知見: <ファイル名と、どの knowledge 引数に入れたか>
- 見立て: <どの step で詰まりそうか、何回くらいで収束しそうか>

## 実行コマンド
（§5 のコマンドをそのまま）

## 結果
（retro で書く）

## 振り返り
（retro で書く）
```

## タスク文（task.md）

takt の全 step に `{task}` として渡る。エージェントが issue を開かなくても進められるように書く。

```markdown
# <やること 1 行>

issue: <URL>

## 背景
<なぜ必要か。issue 本文から要点だけ>

## やること
- <受け入れ条件を、確かめられる形で>

## やらないこと
- <範囲外。触ってほしくない場所>

## 確かめ方
- <走らせるテスト、見るべき画面、使うコマンド>
```

issue のコメントで仕様が変わっていたら、変わった後の内容で書く。

## 振り返り

order.md の 2 節を埋める。

```markdown
## 結果
- run: <.takt/runs/... の path>
- status: <completed | failed（reason）| aborted>
- 往復: <plan → implement → review ×N → ...。trace.md から>
- 差分: <変更ファイル数と主な変更>
- 人が直したところ: <run の後に手で直したもの。無ければ「なし」>

## 振り返り
- 見立てとの差: <当たった / 外れたところ>
- 効いた知見: <差し込んだもののうち、レビューや実装で実際に使われたもの>
- 足りなかった知見: <あれば最初から渡せたもの>
- 次は: <同じ型の issue で変えること>
```

「人が直したところ」と「足りなかった知見」が次の発注で一番効く。曖昧にせず具体的に書く。

## playbook.md の項目

1 項目は次の形。同じ型が既にあれば項目を足さず、その項目の「実績」を更新する。

```markdown
### <issue の型。例: 既存画面の表示条件の変更（フロント 1 repo）>
- WF: <使った WF と差し込んだ知見>
- 実績: <発注ID>（completed, review 2 往復）, <発注ID>（failed: rule_no_match）
- 次は: <変えること。うまくいっていれば「このまま」>
```

## 昇格

- knowledge: `orders/<ID>/knowledge.md` の一部を `facets/knowledge/<repo>.md` などへ移す。
  移すのは、2 回目の発注でも使った知見か、repo 全体に当てはまると確かめた知見だけ
- WF: `orders/<ID>/workflow.yaml` を `workflows/<型の名前>.yaml` へ写し、issue 固有の knowledge を外す。
  相対パスは `../facets/...` に直す。README.md の一覧に 1 行足す
- 昇格したら、元にした order.md の振り返りに「昇格: <移した先>」と書く
