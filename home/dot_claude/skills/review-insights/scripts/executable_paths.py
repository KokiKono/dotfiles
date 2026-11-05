#!/usr/bin/env python3
"""ルールの適用範囲（glob）を決める・照合する。

  paths.py target <agent-files dir> <target_file>   target_file から glob を JSON 配列で出す
  paths.py enrich <candidates.json> <decisions.json> <agent-files dir>
                                                    adopt の判定に paths を足して出す
  paths.py backfill <backlog.json> <agent-files dir> paths を持たない昇格済みエントリに paths を足す（上書き保存）
  paths.py match <rules.json> <files.txt>           files のどれかに当たる rule の id を JSON 配列で出す

glob は Claude Code の rules の paths: と同じ意味で扱う。ユーザーレベルのルールは
セッションの作業ディレクトリ基準で評価されるので、hello-run のセッション
（worktree が 1 段深い）でも当たるよう先頭に **/ を付ける。
"""
import json
import os
import re
import sys


def frontmatter_paths(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    out, in_paths = [], False
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^paths:\s*(.*)$", line)
        if m:
            in_paths = True
            rest = m.group(1).strip()
            if rest:
                # paths: a/**, b/**  /  paths: ["a/**", "b/**"]
                out += [p.strip().strip("\"'") for p in rest.strip("[]").split(",") if p.strip()]
                in_paths = False
            continue
        if in_paths:
            m = re.match(r"^\s+-\s*(.+)$", line)
            if m:
                out.append(m.group(1).strip().strip("\"'"))
            elif line.strip():
                in_paths = False
    return out


def anchor(glob):
    return glob if glob.startswith("**/") else "**/" + glob


def target_paths(agent_dir, target):
    target = (target or "").strip()
    if re.match(r"^\.claude/rules/[^/]+\.md$", target):
        f = os.path.join(agent_dir, target)
        if os.path.isfile(f):
            with open(f, encoding="utf-8") as fh:
                return [anchor(g) for g in frontmatter_paths(fh.read())]
        return []
    m = re.match(r"^(.+)/(CLAUDE|AGENTS)\.md$", target)
    if m:
        return [anchor(m.group(1) + "/**")]
    # ルートの CLAUDE.md / AGENTS.md 向けはファイル種別に結び付かない横断ルール
    return []


def glob_re(glob):
    i, out = 0, ""
    while i < len(glob):
        if glob.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif glob.startswith("**", i):
            out += ".*"; i += 2
        elif glob[i] == "*":
            out += "[^/]*"; i += 1
        elif glob[i] == "?":
            out += "[^/]"; i += 1
        elif glob[i] == "{":
            j = glob.index("}", i)
            out += "(?:" + "|".join(re.escape(a) for a in glob[i + 1:j].split(",")) + ")"; i = j + 1
        else:
            out += re.escape(glob[i]); i += 1
    return re.compile("^" + out + "$")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "target" and len(argv) == 4:
        print(json.dumps(target_paths(argv[2], argv[3])))
    elif cmd == "enrich" and len(argv) == 5:
        with open(argv[2]) as f:
            cand = {c["id"]: c for c in json.load(f)}
        with open(argv[3]) as f:
            dec = json.load(f)
        for d in dec:
            if d.get("verdict") == "adopt":
                d["paths"] = target_paths(argv[4], cand.get(d["id"], {}).get("target_file"))
        print(json.dumps(dec, ensure_ascii=False))
    elif cmd == "backfill" and len(argv) == 4:
        with open(argv[2]) as f:
            bl = json.load(f)
        n = 0
        for e in bl:
            if e.get("status") == "promoted" and e.get("auto") and "paths" not in e:
                e["paths"] = target_paths(argv[3], e.get("target_file"))
                n += 1
        if n:
            with open(argv[2], "w") as f:
                json.dump(bl, f, ensure_ascii=False, indent=2)
        print(n)
    elif cmd == "match" and len(argv) == 4:
        with open(argv[2]) as f:
            rules = json.load(f)
        with open(argv[3]) as f:
            files = [l.strip() for l in f if l.strip()]
        hit = [r["id"] for r in rules
               if any(glob_re(g).match(p) for g in r.get("paths") or [] for p in files)]
        print(json.dumps(hit))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
