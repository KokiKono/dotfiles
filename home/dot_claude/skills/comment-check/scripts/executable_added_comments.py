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
# 後ろに付く側は前後に空白を求める（文字列の中の # や、URL の // を拾わないため）。
# 拾いすぎても subagent が読む行が増えるだけなので、厳密な構文解析はしない
FULL = {
    "hash": re.compile(r"^\s*#(?!!)"),
    "slash": re.compile(r"^\s*(//|/\*|\*|\{/\*)"),
    "dash": re.compile(r"^\s*--"),
}
TRAILING = {
    "hash": re.compile(r"\s#\s"),
    "slash": re.compile(r"\s//\s|/\*"),
    "dash": re.compile(r"\s--\s"),
}
# 道具への指示は、人に読ませる説明ではないので見直しの対象にしない
DIRECTIVE = re.compile(
    r"frozen_string_literal|rubocop:|eslint-|oxlint-|biome-ignore|prettier-ignore|shellcheck |"
    r"@ts-(expect-error|ignore|nocheck)|typed:|coding[:=]|noqa|type: ignore|istanbul ignore|"
    r"^\s*(\*/|/\*\*?|\*)\s*$"
)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout


def default_base(repo):
    for ref in ("origin/HEAD", "origin/main", "origin/master"):
        r = subprocess.run(["git", "-C", repo, "merge-base", ref, "HEAD"], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout.strip()
    sys.exit("既定ブランチが見つからない（--base で指定する）")


def added_lines(repo, base):
    """{path: 足した行番号の集合}。未追跡のファイルは None（全行）"""
    added, current = {}, None
    for line in git(repo, "diff", "-U0", "--diff-filter=d", base).splitlines():
        if line.startswith("+++ b/"):
            current = added.setdefault(line[6:], set())
        elif line.startswith("@@") and current is not None:
            start, _, length = line.split()[2][1:].partition(",")
            current.update(range(int(start), int(start) + int(length or 1)))
    for rel in git(repo, "ls-files", "--others", "--exclude-standard").splitlines():
        added[rel] = None
    return added


def is_comment(line, kind):
    return bool(FULL[kind].search(line) or TRAILING[kind].search(line)) and not DIRECTIVE.search(line)


def blocks_of(repo, rel, numbers):
    kind = next((k for k, exts in KINDS.items() if Path(rel).suffix in exts), None)
    if kind is None:
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
    repo = git(args.repo, "rev-parse", "--show-toplevel").strip()
    base = args.base or default_base(repo)
    blocks = [b for rel, numbers in sorted(added_lines(repo, base).items()) for b in blocks_of(repo, rel, numbers)]
    json.dump({"base": base, "count": len(blocks), "blocks": blocks}, sys.stdout, ensure_ascii=False, indent=1)
    print()


if __name__ == "__main__":
    main()
