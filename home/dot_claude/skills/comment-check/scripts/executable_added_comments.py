#!/usr/bin/env python3
"""差分で足したコメントを、連続する行ごとのかたまりにして JSON で出す。

使い方: added_comments.py [--base <ref>] [<repo>]
  既定の base は、既定ブランチとの merge-base。作業ツリーまで（未コミット・未追跡を含む）を見る。
出力: {"base": ..., "count": N, "blocks": [{"file", "start", "end", "text"}]}
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

KINDS = {
    "hash": {".rb", ".rake", ".py", ".sh", ".bash", ".zsh", ".bats", ".yml", ".yaml", ".toml", ".tf"},
    "slash": {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".go", ".rs", ".java", ".kt", ".swift",
              ".c", ".h", ".cpp", ".cs", ".php", ".scss"},
    "dash": {".sql", ".lua"},
}
# 行の頭から始まるコメントと、コードの後ろに付くコメント。
# 後ろに付く # と // には前後に空白を求める（文字列の中の # や、URL の // を拾わないため）。
# /* だけは空白を求めない。JSX の {/* */} は { の直後に書くため。
# 拾いすぎても subagent が読む行が増えるだけなので、厳密な構文解析はしない
COMMENT = {
    "hash": re.compile(r"^\s*#(?!!)|\s#\s"),
    "slash": re.compile(r"^\s*(//|\*(\s|/|$))|\s//\s|/\*"),
    "dash": re.compile(r"^\s*--|\s--\s"),
}
# 道具への指示と、ブロックコメントの枠だけの行（/** や */）は、読ませる説明が無いので見直しの対象にしない
DIRECTIVE = re.compile(
    r"frozen_string_literal|rubocop:|eslint-|oxlint-|biome-ignore|prettier-ignore|shellcheck |"
    r"@ts-(expect-error|ignore|nocheck)|typed:|coding[:=]|noqa|type: ignore|istanbul ignore|"
    r"^\s*(\*/|/\*\*?|\*)\s*$"
)


def git(repo, *args, check=True):
    # 利用者の設定（パスの引用）で出力の形が変わらないようにする
    return subprocess.run(["git", "-C", repo, "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=check)


def default_base(repo):
    for ref in ("origin/HEAD", "origin/main", "origin/master"):
        r = git(repo, "merge-base", ref, "HEAD", check=False)
        if r.returncode == 0:
            return r.stdout.strip()
    sys.exit("既定ブランチが見つからない（--base で指定する）")


def added_lines(repo, base):
    """{path: 足した行番号の集合}。未追跡のファイルは None（全行）"""
    added, current, in_header = {}, None, False
    diff = git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
               "--diff-filter=d", base).stdout
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current, in_header = None, True
        elif in_header and line.startswith("+++ "):
            # ヘッダーの中だけで見る。`++ b/` で始まる足した行も `+++ b/` で始まるため
            current = added.setdefault(line[6:], set()) if line.startswith("+++ b/") else None
        elif line.startswith("@@") and current is not None:
            in_header = False
            start, _, length = line.split()[2][1:].partition(",")
            current.update(range(int(start), int(start) + int(length or 1)))
    for rel in git(repo, "ls-files", "--others", "--exclude-standard").stdout.splitlines():
        added[rel] = None
    return added


def is_comment(line, kind):
    return bool(COMMENT[kind].search(line)) and not DIRECTIVE.search(line)


def blocks_of(repo, rel, numbers):
    kind = next((k for k, exts in KINDS.items() if Path(rel).suffix in exts), None)
    if kind is None or numbers == set():
        return
    try:
        lines = (Path(repo) / rel).read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return
    block = None
    for no, line in enumerate(lines, 1):
        if (numbers is None or no in numbers) and is_comment(line, kind):
            if block and block["end"] == no - 1:
                block["end"] = no
                block["text"] += "\n" + line
            else:
                if block:
                    yield block
                block = {"file": rel, "start": no, "end": no, "text": line}
    if block:
        yield block


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base")
    parser.add_argument("repo", nargs="?", default=".")
    args = parser.parse_args()
    repo = git(args.repo, "rev-parse", "--show-toplevel").stdout.strip()
    base = args.base or default_base(repo)
    blocks = [b for rel, numbers in sorted(added_lines(repo, base).items()) for b in blocks_of(repo, rel, numbers)]
    json.dump({"base": base, "count": len(blocks), "blocks": blocks}, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
