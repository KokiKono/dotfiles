---
name: hello-issue
description: Slack のスレッド・Notion・既存の issue / PR・口頭のメモなど、渡された材料から勤務先の GitHub issue を起票する。材料を読んで「要求（なぜ・何をしたいか）」と「要件（何を満たせば完了か）」だけを整理し、実装方法は書かない（着手時に別途決める）。起票した issue は自分にアサインし、設定の GitHub Project に紐づける。「issue 立てて」「issue にして」「起票して」「このスレッドを issue 化して」「この Slack を元にチケット作って」「要件まとめて issue に」などと言われたときに使う。Slack や Notion のリンクを渡されて issue の話が出たら、スキル名を言われなくても使うこと。既存の issue を読んで調べるだけなら hello-search、issue から作業環境を作るなら hello-run を使う。
argument-hint: "<Slack / Notion / GitHub のリンクやメモ> | setup"
---

# hello-issue

依頼は Slack のスレッドや会議のメモで届くことが多く、そのままでは「何が決まっていて、何を作れば終わりか」が
読み取りにくい。このスキルは材料を読み、**要求と要件だけ**を issue に起こす。

実装方法を書かないのは、起票の時点ではコードを読み込んでおらず、書いた方針が着手時の判断を縛るから。
どう作るかは、着手したときに hello-run のセッションで決める。

## 0. 設定を読む

```bash
cat ~/.claude/hello-issue.local.json
```

| キー | 意味 |
|---|---|
| `repo` | 起票先の既定のリポジトリ（`<owner>/<repo>`）。材料から別のリポジトリと分かればそちらを優先する |
| `project_owner` | 紐づける GitHub Project の所有者（org） |
| `project_number` | その Project の番号 |
| `labels` | 毎回付けるラベルの配列（空でよい） |
| `dry_run` | `true` なら起票せず、作る内容を表示するだけ |

**このファイルは追跡外**（スキル本体は public リポジトリにある）。
無い / `repo` か `project_number` が空なら `setup` モードへ。引数が `setup` のときも同じ。

## 1. 材料を読む

渡されたものを全部、中身まで読む。互いに依存しないので、0. の設定の読み込みも含めて 1 回の応答でまとめて呼ぶ。

| 材料 | 読み方 |
|---|---|
| Slack のリンク | Slack MCP の `slack_read_thread`。親だけでなく返信まで読む。結論は後半の返信で変わっていることが多い |
| Notion のリンク | Notion MCP の `notion-fetch`。`truncated` が返ったら続きも取る |
| GitHub の issue / PR | `gh issue view <url> --comments` / `gh pr view <url> --comments` |
| 口頭のメモ・貼り付けた文 | そのまま材料にする |

各ソースの読み方の詳細は hello-search の `~/.claude/skills/hello-search/references/sources.md` にある。

読めなかったもの（権限が無い、リンク切れ）は推し量って埋めず、下書きを見せるときにそう伝える。
材料に出てくる別のリンクは、要求を理解するのに要るものだけ 1 段だけたどる。

## 2. 重複を確かめる

```bash
gh search issues --repo <repo> --state open "<要求の要点を表す語>" --limit 10
```

同じ要求の open な issue があれば、起票せずにその URL を見せて「新しく立てるか、そこへ追記するか」を聞く。

## 3. 要求と要件に整理する

本文は次の形にする。材料に無いことは書かない。

```markdown
## 背景
<誰が・どんな場面で・何に困っているか。2〜4 文>

## 要求
<何を実現したいか。利用者や依頼者の言葉に近い粒度で>

## 要件
- [ ] <満たせば完了と判断できる条件。画面・データ・振る舞いの単位で、確かめられる書き方にする>

## スコープ外
- <今回やらないと決まっていること。材料に無ければ節ごと省く>

## 未確定事項
- <決まっていないこと / 誰に確認するか。無ければ節ごと省く>

## 参考
- [<出典の名前>](<URL>)（YYYY-MM-DD）
```

- **要求と要件を分ける。** 要求は「なぜ・何を」、要件は「何を満たせば終わりか」。
  要件が書けないなら、それは未確定事項に回す
- **実装方法を書かない**（理由は冒頭のとおり）。テーブル設計、API の形、使うライブラリ、触るファイルは書かない。
  材料の中で実装の議論が進んでいても、要件に効く結論（「既存の○○画面から使えること」など）だけを拾う
- **決まっていないことを決まったように書かない。** 議論が割れていれば、両案を未確定事項に並べる
- 参考には読んだ材料を全部リンクで並べる。issue を開いた人が元の議論にたどれるようにするため
- タイトルは「何ができるようになるか」を 1 文で。「○○対応」「○○の件」のような中身の分からない名前にしない

## 4. 下書きを見せて確認を取る

issue の起票は他の人に見える操作なので、**作る前に必ず下書きを見せて承認を得る**。見せるのは:

- 起票先のリポジトリ、タイトル、本文
- アサイン（自分）、紐づける Project、ラベル
- 読めなかった材料・重複候補があればそれも

直しの指示があれば直して見せ直す。`dry_run` が `true` ならここで終える。

## 5. 起票する

本文はファイルに書いてから渡す（シェルのクォートで崩さないため）。置き場はスクラッチパッドか `mktemp`。

```bash
gh issue create --repo <repo> --title "<タイトル>" --body-file <本文のファイル> \
  --assignee @me [--label <label> ...]
gh project item-add <project_number> --owner <project_owner> --url <issue の URL>
```

`gh issue create --project <title>` で一度に済ませないのは、タイトルでの引き直しが挟まるうえ、
`project` スコープが無いと issue ごと作られず、作り直しで二重起票しやすいから。
`item-add` が `project` スコープ不足で落ちたら、ユーザーに `! gh auth refresh -s project` を叩いてもらってから
`item-add` だけやり直す。

## 6. 報告する

```
📝 <repo>#<N> 「<タイトル>」を起票（<URL>）。自分にアサイン、Project に追加済み
```

Project への追加が失敗したまま終わる場合は、そのことを書く。

## setup モード

1. 起票先のリポジトリを決める。`~/.pzshrc` の `HELLO_RUN_ISSUE_REPO` があればそれを既定として提案する
   （org は `~/.claude/hello-search.local.json` の `github_owner` があればそれと揃える）:
   `zsh -c 'source ~/.pzshrc; print $HELLO_RUN_ISSUE_REPO'`
2. その org の Project を一覧し、どれに紐づけるか聞く:
   `gh project list --owner <org> --format json --jq '.projects[] | [.number, .title] | @tsv'`
   （`project` スコープが無ければ `! gh auth refresh -s project` を案内する）
3. `~/.claude/hello-issue.local.json` に書く。`dry_run` は最初 `true` にし、数回ためしてから `false` にするよう勧める

## 守ること

- **Slack・Notion には書き込まない。** 起票した旨を元のスレッドに返すのはユーザーに任せる
- **社内の固有名詞をこのスキルのファイルに書かない。** 例が要るときは `○○` / `△△` にする。
  public リポジトリに入っている
