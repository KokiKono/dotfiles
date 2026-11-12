# review-before-pr.sh（作成前）と pr-followup.sh（作成後）が source する。
# 判定が両者でずれると、レビューを求めたのにフォローされない PR ができるので 1 か所に置く。

# コマンドの改行は ; に畳んでから当てること。
# コミットメッセージや grep の引数に含まれるだけのものは対象にしない。
# 先頭の環境変数の代入（GH_TOKEN=x gh pr create など）は越えて見る
GH_PR_CREATE_RE='(^|[;&|])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+create'
