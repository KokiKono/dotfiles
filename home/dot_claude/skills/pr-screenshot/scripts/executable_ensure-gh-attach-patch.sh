#!/usr/bin/env bash
# gh-attach 拡張に必要なローカル修正2件を検査し、欠けていれば当て直す（冪等）。
# `gh extension upgrade` で修正が消えるため、アップロード前に毎回実行してよい。
set -uo pipefail

BIN="${GH_ATTACH_BIN:-$HOME/.local/share/gh/extensions/gh-attach/bin/gh-attach}"

if [[ ! -f "$BIN" ]]; then
  echo "NG: gh-attach が見つかりません: $BIN" >&2
  echo "→ gh extension install で gh-attach を入れてから再試行してください。" >&2
  exit 2
fi

python3 - "$BIN" <<'PY'
import re, shutil, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
original = src
applied, missing = [], []

# 修正1: ログイン待ちの URL 判定が /issues/ のみだと、PR は /pull/ にリダイレクトされて必ずタイムアウトする。
if '"/pull/"' in src:
    pass
elif '"/issues/"*' in src:
    src = src.replace(
        '"$current_url" == *"/issues/"*',
        '"$current_url" == *"/issues/"* || "$current_url" == *"/pull/"*',
        1,
    )
    applied.append("ログイン待ちの URL 判定に /pull/ を追加")
else:
    missing.append("修正1: ログイン待ちの URL 判定（/issues/ を含む条件が見つからない）")

# 修正2: 新しい playwright-cli は snapshot をファイルではなく標準出力に出すため、
# ファイル前提の ref 探索が "Could not find upload button" になる。
if re.search(r'if \[\[ -n "\$snap_file" && -f "\$snap_file" \]\]', src):
    pass
else:
    m = re.search(r'([ \t]*)snap_out=\$\(cat "\$snap_file"\)\n', src)
    if m:
        indent = m.group(1)
        src = src.replace(
            m.group(0),
            f'{indent}# Newer playwright-cli prints the snapshot inline instead of writing a file.\n'
            f'{indent}if [[ -n "$snap_file" && -f "$snap_file" ]]; then\n'
            f'{indent}  snap_out=$(cat "$snap_file")\n'
            f'{indent}fi\n',
            1,
        )
        applied.append("snapshot をファイル不在時は標準出力から読むよう変更")
    else:
        missing.append('修正2: snapshot の読み取り箇所（snap_out=$(cat "$snap_file") が見つからない）')

if src != original:
    shutil.copy2(path, path + ".bak")
    open(path, "w", encoding="utf-8").write(src)

for a in applied:
    print(f"適用: {a}")
if not applied and not missing:
    print("OK: ローカル修正2件はすでに適用済み。")
if missing:
    print("NG: 自動適用できませんでした（拡張の実装が変わった可能性）:", file=sys.stderr)
    for m_ in missing:
        print(f"  - {m_}", file=sys.stderr)
    print(f"→ {path} を直接読んで手で当て、変わった箇所に合わせてこのスクリプトの検出条件も直してください。", file=sys.stderr)
    sys.exit(1)
PY
