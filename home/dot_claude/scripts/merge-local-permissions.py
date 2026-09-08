#!/usr/bin/env python3
"""
Stop hook: settings.local.json の permissions.allow を
プロジェクトの settings.json にマージし、重複排除・ダイエットを適用する。

ダイエットルール:
  1. 完全重複の排除
  2. prefix:* ワイルドカードへの吸収
     例) Bash(git log --oneline) は Bash(git:*) があれば削除
  3. /** グロブワイルドカードへの吸収
     例) Read(path/sub/**) は Read(path/**) があれば削除
  4. 一時的なエントリの削除
     - Bash(kill -0 <PID>)
     - Bash(CEKERNEL_IPC="...")
     - Bash(git -C .../worktrees/...)
     - Bash(__NEW_LINE_... )
     - Bash(/dev/null ...)
"""

import json
import os
import re
import subprocess
import sys


# ── パース ──────────────────────────────────────────────────────────────────

def parse_rule(rule: str):
    """
    Returns (tool, arg, is_prefix_wildcard)
    - is_prefix_wildcard=True  → Tool(prefix:*)
    - is_prefix_wildcard=False → Tool(exact) or Tool(path/**)
    """
    m = re.match(r'^(\w+)\((.+)\)$', rule, re.DOTALL)
    if not m:
        return rule, None, False
    tool, arg = m.group(1), m.group(2)
    if arg.endswith(':*'):
        return tool, arg[:-2], True
    return tool, arg, False


# ── 一時的エントリの判定 ──────────────────────────────────────────────────

def is_ephemeral(rule: str) -> bool:
    # kill -0 <PID>
    if re.match(r'^Bash\(kill -0 \d+\)$', rule):
        return True
    # CEKERNEL_IPC 固定ソケットパス
    if re.match(r'^Bash\(CEKERNEL_IPC="[^"]+"\)$', rule):
        return True
    # ワークツリー専用パスへの git コマンド
    if re.match(r'^Bash\(git -C .+[/\\]\.worktrees[/\\].+\)', rule):
        return True
    # __NEW_LINE__ 系のアーティファクト
    if re.match(r'^Bash\(__NEW_LINE_[a-f0-9]+__', rule):
        return True
    # /dev/null 系のアーティファクト
    if re.match(r'^Bash\(/dev/null', rule):
        return True
    return False


# ── ダイエット ──────────────────────────────────────────────────────────────

def diet(allows: list) -> list:
    # 1. 完全重複排除（順序保持）
    seen = set()
    deduped = []
    for r in allows:
        if r not in seen:
            seen.add(r)
            deduped.append(r)

    parsed = [parse_rule(r) for r in deduped]

    # 2. ワイルドカードインデックス構築
    prefix_wc = {}   # tool -> [prefix, ...]  (prefix:* 型)
    glob_wc   = {}   # tool -> [path_base, ...] (path/** 型)

    for rule, (tool, arg, is_wc) in zip(deduped, parsed):
        if is_ephemeral(rule):
            continue
        if is_wc:
            prefix_wc.setdefault(tool, []).append(arg)
        elif arg and arg.endswith('/**'):
            glob_wc.setdefault(tool, []).append(arg[:-3])  # /** を除いたベース

    result = []
    for rule, (tool, arg, is_wc) in zip(deduped, parsed):
        # 一時的エントリを除去
        if is_ephemeral(rule):
            continue

        # prefix:* ワイルドカードに吸収されるか確認
        if not is_wc and arg is not None:
            if any(arg.startswith(p) for p in prefix_wc.get(tool, [])):
                continue  # 吸収 → スキップ

        # /** グロブに吸収されるか確認
        if not is_wc and arg and arg.endswith('/**'):
            base = arg[:-3]
            if any(base.startswith(gp + '/') for gp in glob_wc.get(tool, [])):
                continue  # 吸収 → スキップ

        result.append(rule)

    return result


# ── メイン ──────────────────────────────────────────────────────────────────

def main():
    raw = sys.stdin.read()

    # cwd を stdin JSON または os.getcwd() から取得
    cwd = os.getcwd()
    if raw.strip():
        try:
            data = json.loads(raw)
            cwd = data.get('cwd') or cwd
        except json.JSONDecodeError:
            pass

    local_path  = os.path.join(cwd, '.claude', 'settings.local.json')
    target_path = os.path.join(cwd, '.claude', 'settings.json')

    if not os.path.exists(local_path):
        sys.exit(0)

    with open(local_path) as f:
        local_settings = json.load(f)

    local_allows = local_settings.get('permissions', {}).get('allow', [])
    if not local_allows:
        sys.exit(0)

    # target (settings.json) を読み込む（なければ空）
    if os.path.exists(target_path):
        with open(target_path) as f:
            target_settings = json.load(f)
    else:
        target_settings = {}

    target_allows_before = target_settings.get('permissions', {}).get('allow', [])

    merged = diet(target_allows_before + local_allows)

    target_settings.setdefault('permissions', {})['allow'] = merged

    with open(target_path, 'w') as f:
        json.dump(target_settings, f, indent=2, ensure_ascii=False)
        f.write('\n')

    # マージ済みの local_allows をクリア
    local_settings.setdefault('permissions', {})['allow'] = []
    with open(local_path, 'w') as f:
        json.dump(local_settings, f, indent=2, ensure_ascii=False)
        f.write('\n')

    added = len(merged) - len(target_allows_before)
    removed = len(local_allows) - max(added, 0)

    # 変更があればコミット
    commit_msg = ""
    if added > 0:
        try:
            rel_target = os.path.relpath(target_path, cwd)
            subprocess.run(
                ['git', '-C', cwd, 'add', rel_target],
                check=True, capture_output=True
            )
            result = subprocess.run(
                ['git', '-C', cwd, 'commit', '-m',
                 f'chore: セッション終了時の permissions を自動マージ ({max(added,0)} 件追加)'],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                commit_msg = " → コミット完了"
            else:
                commit_msg = f" → コミット失敗: {result.stderr.strip()}"
        except Exception as e:
            commit_msg = f" → コミットエラー: {e}"

    print(json.dumps({
        "systemMessage": (
            f"permissions を settings.json にマージ完了: "
            f"{len(merged)} 件 (追加 {max(added,0)} 件, ダイエット {removed} 件){commit_msg}"
        )
    }))


if __name__ == '__main__':
    main()
