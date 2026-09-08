# プロンプトエンジニアリング・ベストプラクティス（診断チェックリスト）

出典: Anthropic「プロンプト作成のベストプラクティス」
https://platform.claude.com/docs/ja/build-with-claude/prompt-engineering/claude-prompting-best-practices

以下は診断時に照らすチェック項目。**該当するものだけ**を指摘に使う。全部を機械的に当てはめない。

1〜11 は世代に依らない原則として書いてある。特定のモデル番号に紐づく挙動（どの版が何に過敏か等）は
陳腐化するので末尾の付録にまとめ、確認日を添えた。診断の根拠に版依存の話を持ち出すときは、その確認日を見る。

## 目次

1. 明確さ・具体性
2. 文脈（なぜ）を添える
3. 例（few-shot）
4. XML タグでの構造化
5. 役割付与
6. やらないこと、ではなくやること
7. ツール使用のトリガー
8. 過剰プロンプトの害（★最重要・見落とされやすい）
9. 思考・推論（adaptive thinking / effort）
10. エージェント挙動（自律性・安全性・過剰積極性）
11. 長いコンテキスト
12. 旧世代からの移行で直すべき点
付録. 世代別の既知の癖（版依存・要確認）

---

## 1. 明確さ・具体性

- **黄金律**: 最小限の文脈しか持たない同僚にそのプロンプトを見せて、混乱するなら Claude も混乱する。
- 望む出力形式・制約を具体的に指定する。「期待以上」を望むなら曖昧にせず明示的にリクエストする。
- 手順の順序・完全性が重要なら番号付きリストで順序立てる。
- Do: `Create an analytics dashboard. Include as many relevant features and interactions as possible. Go beyond the basics...`
- Don't: `Create an analytics dashboard`（曖昧すぎ）

## 2. 文脈（なぜ）を添える

- 指示の背景・動機・「なぜ重要か」を説明すると、モデルは目標を深く理解し般化できる。
- Do: `Your response will be read aloud by a text-to-speech engine, so never use ellipses since the engine will not know how to pronounce them.`
- Don't: `NEVER use ellipses`（理由なし。般化できない）

## 3. 例（few-shot / multishot）

- 出力の形・トーン・構造を誘導する最も信頼できる手段。3〜5 個が目安。
- **関連性**（実ユースケースを反映）・**多様性**（エッジケースを含め、意図しないパターンを学習させない）・**構造化**（`<example>` / 複数は `<examples>` で囲む）。

## 4. XML タグでの構造化

- 指示・文脈・例・入力が混在するとき、`<instructions>` `<context>` `<input>` `<example>` 等で囲むと誤解釈が減る。
- 一貫した説明的なタグ名を使う。自然な階層があればネストする。

## 5. 役割付与

- system プロンプトで役割を与えると、挙動とトーンがユースケースに焦点化する。一文でも効く。
- 例: `You are a helpful coding assistant specializing in Python.`

## 6. やらないこと、ではなくやること（★頻出）

- 「〜するな」より「〜せよ」の方が効く。
  - `応答にマークダウンを使うな` → `滑らかに流れる散文の段落で構成する`
- XML フォーマット指示子も有効: `<smoothly_flowing_prose_paragraphs>` タグ内に書く、等。
- プロンプト自身のスタイルを望む出力に合わせる（プロンプトからマークダウンを削ると出力のマークダウンも減る）。

## 7. ツール使用のトリガー

- 現行モデルは指示追従が正確。アクションさせたいなら明示的に。
  - Don't: `Can you suggest some changes to improve this function?`（提案だけで終わる）
  - Do: `Change this function to improve its performance.` / `Make these edits to the authentication flow.`
- デフォルトで積極的に動かしたい / 慎重にさせたい は、`<default_to_action>` / `<do_not_act_before_instructions>` のブロックで制御。
- 並列ツール呼び出しを最大化したいなら `<use_parallel_tool_calls>` ブロックを使う。

## 8. 過剰プロンプトの害（★最重要・Claude Code 指示文で最も見落とされる）

- 現行世代は system プロンプトへの感度が高い。旧モデルのアンダートリガー対策として書いた強い表現は、いまは**オーバートリガー**を起こす。
  - `CRITICAL: You MUST use this tool when...` → `Use this tool when...` に弱める。
  - `迷ったら [tool] を使う` のような指示はオーバートリガーの原因。削る。
  - `デフォルトで [tool] を使う` → `問題の理解を深めるのに役立つ場合に [tool] を使う` に的を絞る。
- **過剰積極性 / オーバーエンジニアリング**: 余分なファイル作成・不要な抽象化・頼まれていない柔軟性を足しがち。最小限に保つガイドを入れる（下記の定型片参照）。
- **サブエージェントの過剰使用**: 直接 grep で足りる場面でもサブエージェントを立てる傾向がある。使う/使わないの線引きを明示する。
- 総じて、Claude Code 向け指示文の改善は「足す」より「削って理由に置き換える」ことが多い。

### 定型片: オーバーエンジニアリング抑制
```
Avoid over-engineering. Only make changes that are directly requested or clearly
necessary. Keep solutions simple and focused: don't add features/refactors/abstractions
beyond what was asked; don't add docstrings/comments to code you didn't change; don't add
defensive error handling for scenarios that can't happen (validate only at system
boundaries).
```

### 定型片: サブエージェント使用の線引き
```
Use subagents when tasks can run in parallel, require isolated context, or involve
independent workstreams. For simple tasks, sequential operations, single-file edits, or
tasks where you need to maintain context across steps, work directly rather than delegating.
```

## 9. 思考・推論（adaptive thinking / effort）

- 現行モデルは adaptive thinking（`thinking: {type: "adaptive"}`）＋ `effort` で思考量を動的に決める。固定の `budget_tokens` は新しい版では受け付けられない（付録参照）。
- 規定的なステップより一般的な指示（「徹底的に考えて」）の方が良い推論を生むことが多い。
- 自己チェックを促す一文は有効: `終了する前に [テスト基準] に照らして回答を検証して`。
- 過剰思考を抑えたいなら「アプローチを一つ選んでコミットし、矛盾する新情報がない限り再検討しない」系の指示。
- 版によっては拡張思考オフ時に "think" という語へ過敏に反応する（付録参照）。避けたいなら `consider` / `evaluate` / `reason through` に言い換える。

## 10. エージェント挙動（自律性・安全性）

- ガイダンスがないと、不可逆・共有システムに影響する操作（削除・force push・外部投稿）をそのまま実行しうる。リスク操作の前に確認させる `<reversibility>` 系ガードを入れる。
- 長期タスクではコンテキスト管理・状態追跡（git、`tests.json`、`progress.txt`）を促す指示が効く。
- ハルシネーション抑制: `<investigate_before_answering>`（開いていないコードについて推測しない、参照ファイルは必ず読む）。

## 11. 長いコンテキスト（20,000 トークン以上）

- 長文データはプロンプトの**先頭**に置く（クエリ・指示・例より上）。末尾にクエリを置くと最大 30% 品質向上。
- 複数ドキュメントは `<document>` / `<document_content>` / `<source>` で構造化。
- タスク前に関連箇所を `<quotes>` として引用させると、ノイズを排除できる。

## 12. 旧世代からの移行で直すべき点

1. 望む挙動を具体的に記述する。
2. 修飾語で品質・詳細を引き上げる（「できるだけ多くの関連機能を含めて」）。
3. アニメーション等の機能は必要なら明示的にリクエスト。
4. 思考設定を `budget_tokens` から adaptive thinking + `effort` に更新。
5. プリフィル応答に依存した設計をやめ、system プロンプトの指示 / Structured Outputs / ツール呼び出しに移行する（非対応の版がある。付録参照）。
6. **怠惰防止・徹底化プロンプトを控えめに**（＝項目 8）。旧モデルで必要だった強い指示はオーバートリガーを起こす。

---

## 付録: 世代別の既知の癖（版依存）

最終確認: 2026-08-20 / 確認済みの範囲: Claude Opus 4.5〜4.8, Sonnet 5, Fable 5 世代。
**Opus 5 以降では未検証。**以下を診断の根拠にするなら、対象モデルで再現するか確かめてから言う。
「昔そう言われていた」を現行の欠陥として指摘すると、直す必要のない箇所を直させてしまう。

- Opus 4.5 / 4.6 / 4.8 は system プロンプトの強い表現に敏感で、`CRITICAL` / `You MUST` の多用がオーバートリガーを招いた。
- Opus 4.6 はサブエージェントを好み、直接 grep で足りる場面でも委譲した。
- Opus 4.6 はガイダンス無しで不可逆操作（削除・force push・外部投稿）を実行することがあった。
- 拡張思考オフ時、Opus 4.5 は "think" という語に過敏だった。
- `budget_tokens` は Opus 4.7 以降および Fable 5 で 400 エラーになる。
- プリフィル応答は Opus 4.6 以降で非対応。

版に依らず成り立つと考えていること（本文 1〜11 に書いた内容）と、この付録は分けて扱う。
新しい世代で挙動差を観測したら、この付録に日付付きで追記する。
