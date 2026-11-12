---
name: pr-followup
description: PR を作ったあとの作業を、指摘が無くなるまで自動で回す。CI を見張って落ちたら直し、bot が付けた i18n の警告を解消し、Draft で残タスクが無ければ claude-review ラベルを付けて AI レビューを始め、claude-review の指摘を直すか理由を返信する。gh pr create の後に hook（pr-followup.sh）から呼ばれる。「PR のフォローして」「CI 直して」「レビュー対応して」「claude-review の指摘に対応して」「i18n の警告を消して」などと言われたときにも使う。
argument-hint: "[PR の URL | 番号]"
---

# pr-followup

PR を作ったあとは毎回、CI を待って直し、i18n の警告を消し、AI レビューの指摘に対応する。
このスキルはそれを最後まで回す。`gh pr create` が成功すると hook（`~/.claude/hooks/pr-followup.sh`）が
このスキルを実行するよう伝えてくるので、そのまま始めてよい。

このスキルの中では**確認を挟まずに** commit・push・指摘への返信まで進める（ユーザーの指示による。
グローバルの「投稿前に本文案を見せる」の例外はこのスキルの中だけ）。ただし PR 本文の書き換え、
Ready for review への変更、マージはしない。人が書いたコメントにも返信しない。

## 0. 対象を決める

1. 引数の URL か番号の PR を対象にする。無ければ `gh pr view --json url,number` で今のブランチの PR を使う
2. 状態を取る

   ```bash
   ~/.claude/skills/pr-followup/scripts/pr-review-status.py <owner/repo> <番号>
   ```

   `draft` と `labels` を 3 で、`i18n` を 2 で、`state` と `threads` を 4 で使う

関係ないコメントを i18n の警告として拾う、または拾い漏らすことが続いたら、`~/.claude/pr-followup.local.json`
（**追跡外**）の `i18n_bots` / `i18n_pattern` で絞る。キーの意味と既定値はスクリプト冒頭にある。

## 1. CI を待ち、落ちたら直す

1. `gh pr checks <番号> --watch --fail-fast` で待つ。時間がかかるので Bash の `run_in_background` か、
   Monitor の until ループで待つ
2. 落ちたら `gh run view <run-id> --log-failed` で原因を切り分ける
   - **PR の変更が原因**: 直して、関係するテストと lint を手元で通してから commit・push し、1 に戻る
   - **flaky に見える**（変更と無関係の箇所で、エラーがタイムアウトや通信）: `gh run rerun <run-id> --failed` を 1 回だけ試す
   - **既定ブランチでも落ちている、または PR の範囲外**: 止めてユーザーに聞く
3. 3 回直しても通らなければ止めて報告する

## 2. i18n の警告を解消する

`pr-review-status.py` の `i18n` を、4-2 の基準で先に片付ける。CI と同じく AI レビューより先にやるのは、
残したままだと AI レビューも同じ箇所を指摘し、1 周を使うから。

- `kind: "thread"`（未解決のレビューコメント）: 4-2 のとおり直すか返信する
- `kind: "comment"`（PR への普通のコメント）: 解決済みの印が無いので、今の差分にまだ当てはまるかを
  読み、当てはまるものだけ直す

直した分は 1 の CI を待ち直してから 3 に進む。push は 1 と 2 の修正をまとめて 1 回にしてよい。

## 3. AI レビューを始める

claude-review は Ready の PR では open と push のたびに自動で走り、Draft では `claude-review`
ラベルが付くまで走らない。

- **Ready（`draft: false`）**: 何もしない。4 に進む
- **Draft で、ラベルがもう付いている**: 4 に進む
- **Draft で、ラベルが無い**: 会話の中に残タスクが無いかを確かめる
  - 残タスクとみなすもの: TaskList の未完了、ユーザーに頼まれてまだやっていないこと、
    PR 本文やコミットに「後で」「未対応」と書いたこと
  - 無ければ `gh pr edit <番号> --add-label claude-review` を付けて 4 に進む
  - あればラベルを付けず、残タスクを並べて報告して終える。CI と i18n の対応だけで止める
  - 1 と 2 より後にするのは、CI が落ちたまま AI レビューを回すと、落ちた原因の指摘で 1 周を使うから

## 4. 指摘が無くなるまで回す

1. `pr-review-status.py` を Monitor の until ループで回し（30 秒間隔）、`state` が `reviewing` 以外になるまで待つ
   - `clean`: 今の head へのレビューが「0 new」で、未解決の指摘も i18n の警告スレッドも無い。5 に進む
   - `has_findings`: `threads` と `i18n` の各指摘を 2 に回す
2. 指摘ごとに、次のどれかを決める（2 の i18n の警告スレッドも同じ基準）
   - **直す**: 指摘が正しく、PR の目的の範囲に収まる。先にテストを足して落ちることを確かめ、直し、
     関係するテストと lint を通し、指摘ごとに commit する（本文に Why）。返信は書かない。
     push すると claude-review が差分を読み、自分で返信して解決済みにする
   - **直さない**: 誤検知、または issue や PR で決めた仕様どおり。スレッドに理由を 1〜3 文で返信する
     （`gh api repos/<owner>/<repo>/pulls/<番号>/comments/<comment_id>/replies -f body=...`）。
     claude-review は次の実行で返信を読み、解決済みにする
   - **人に聞く**: 仕様の判断が要る、PR の範囲を超える、直すと他の決定とぶつかる。ループを止めてユーザーに聞く
3. push は 1 周に 1 回にまとめる（push のたびに claude-review が走り、前の実行は止まる）。
   push したら 1 の CI を待ち直す。返信だけで push が無いときは、ラベルを付け直して再レビューを起こす
   （`gh pr edit --remove-label claude-review` → `--add-label claude-review`。Ready の PR でも効く）
4. 1 に戻る。**5 周で `clean` にならなければ止めて**、残った指摘と、それぞれをどう判断したかを報告する

## 5. 報告する

次を短く報告する。

- CI を直した回数と、直した原因
- i18n の警告への対応
- AI レビューの周回数と、指摘ごとの扱い（直した / 直さない理由 / 人に聞いた）
- Draft のままラベルを付けなかったなら、その理由の残タスク

## やらないこと

- PR 本文の書き換え、Ready for review への変更、マージ
- 人が書いたレビューコメントへの返信（このスキルが返信するのは bot の指摘だけ）
- 既定ブランチでも落ちている CI の修正（別の PR で直すべきなので、ユーザーに聞く）
