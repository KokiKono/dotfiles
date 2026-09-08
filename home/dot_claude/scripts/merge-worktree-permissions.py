#!/usr/bin/env python3
"""
WorktreeRemove hook: ワークツリーの settings.local.json の permissions.allow を
メインプロジェクトにマージし、重複排除・ダイエットを適用する。

ダイエットルール:
  1. 完全重複の排除
  2. prefix:* ワイルドカードへの吸収
     例) Bash(git log --oneline) は Bash(git log:*) があれば削除
  3. /** グロブワイルドカードへの吸収
     例) Read(path/sub/**) は Read(path/**) があれば削除
  4. 一時的なエントリの削除
     - Bash(kill -0 <PID>)
     - Bash(CEKERNEL_IPC="...")
     - Bash(git -C .../worktrees/...)  ← ワークツリー専用パス
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

def find_main_project(worktree_path: str) -> str | None:
    """git rev-parse --git-common-dir でメインリポジトリを特定"""
    try:
        git_common = subprocess.check_output(
            ['git', '-C', worktree_path, 'rev-parse', '--git-common-dir'],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        # git_common は /path/to/main/.git
        return os.path.dirname(os.path.abspath(git_common))
    except Exception:
        return None


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit(0)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    # WorktreeRemove フックは tool_input.path でパスを渡す想定
    worktree_path = (
        data.get('tool_input', {}).get('path')
        or data.get('worktree_path')
        or data.get('path')
    )

    if not worktree_path or not os.path.isdir(worktree_path):
        sys.exit(0)

    # ワークツリー側の settings.local.json
    wt_settings_path = os.path.join(worktree_path, '.claude', 'settings.local.json')
    if not os.path.exists(wt_settings_path):
        sys.exit(0)

    # メインプロジェクトを特定
    main_root = find_main_project(worktree_path)
    if not main_root:
        sys.exit(0)

    main_settings_path = os.path.join(main_root, '.claude', 'settings.local.json')
    if not os.path.exists(main_settings_path):
        sys.exit(0)

    # 読み込み
    with open(main_settings_path) as f:
        main_settings = json.load(f)
    with open(wt_settings_path) as f:
        wt_settings = json.load(f)

    main_allows = main_settings.get('permissions', {}).get('allow', [])
    wt_allows   = wt_settings.get('permissions', {}).get('allow', [])

    merged = diet(main_allows + wt_allows)

    main_settings.setdefault('permissions', {})['allow'] = merged

    with open(main_settings_path, 'w') as f:
        json.dump(main_settings, f, indent=2, ensure_ascii=False)
        f.write('\n')

    removed = len(main_allows) + len(wt_allows) - len(merged)
    print(json.dumps({
        "systemMessage": f"permissions.allow をマージ・ダイエット完了: {len(merged)} 件 ({removed} 件削減)"
    }))


if __name__ == '__main__':
    main()
