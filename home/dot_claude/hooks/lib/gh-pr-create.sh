# review-before-pr.sh・kb-checks.sh（作成前）と pr-followup.sh（作成後）が source する。
# 判定が hook の間でずれると、レビューを求めたのにフォローされない PR ができるので 1 か所に置く。

# コマンドの改行は ; に畳んでから当てること。
# コミットメッセージや grep の引数に含まれるだけのものは対象にしない。
# 先頭の環境変数の代入（GH_TOKEN=x gh pr create など）は越えて見る
CMD_PREFIX_RE='(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GH_PR_CREATE_RE="${CMD_PREFIX_RE}gh[[:space:]]+pr[[:space:]]+create"

# git commit-graph や git commit-tree を外すため、commit の直後に空白・; ・行末を求める。
# git の全体オプション（-C <path>、-c k=v、--no-pager など）は越えて見る
GIT_COMMIT_RE="${CMD_PREFIX_RE}git[[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+[[:space:]]+|--[a-z-]+(=[^[:space:]]*)?[[:space:]]+)*commit([[:space:]]|;|\$)"
