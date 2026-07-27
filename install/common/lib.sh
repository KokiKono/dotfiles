#!/usr/bin/env bash
# 共通ヘルパー。各 install スクリプトから source して使う。
# 直接実行時には何もしない（source ガードは呼び出し側スクリプトに置く）。
set -Eeuo pipefail

# リポジトリのルート（install/common/lib.sh の 2 つ上）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# ログ出力
log() { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }

# コマンドが存在するか
has() { command -v "$1" >/dev/null 2>&1; }
