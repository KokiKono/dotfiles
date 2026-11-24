# mutations

mutation-check スキルが使う、変異（コードにわざと入れる小さなバグ）の定義と結果の置き場。
書式はスキルの `references/definition.md` にある。

```
mutations/
└── <repo>-<PR番号>/     PR が無ければ <repo>-<ブランチ名>
    ├── candidates.json  差分から機械的に作った候補（gen_mutations.py）
    ├── mutations.json   変異の定義（候補に、subagent が仕様から考えた変異を足したもの）
    ├── result.json      直近の実行結果（run_mutations.py --out）
    └── report.md        何を確かめたかと、見逃したバグ 1 件ずつの対応（対応した / しなかった / できなかった）
```

- 定義は書き換え前の文字列で場所を指すので、コードを直すと古くなる。過去の定義は流し直すためではなく、
  どんな変異が穴を見つけたかを次に活かすために残す
- 結果のキャッシュはここではなく `~/.cache/mutation-check/` にある（消えても流し直せば戻るため）
- 新しく変異を考える前に、同じリポジトリの過去の `report.md` を読む
