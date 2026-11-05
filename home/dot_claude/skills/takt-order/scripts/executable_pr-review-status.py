#!/usr/bin/env python3
"""pr-review-status.py <owner/repo> <PR 番号>

claude-review（.github/workflows/pr-review.yml）のレビュー状況を JSON で出す。

- state
  - "reviewing": 今の head に対するレビューがまだ終わっていない（workflow が実行中・待ち、またはレビュー未投稿）
  - "clean": 今の head へのレビューが「0 new」で、未解決の指摘スレッドも無い。ループを終えてよい
  - "has_findings": 未解決の指摘スレッドがある。threads を見て直すか返信する
- threads: 未解決の claude-review 指摘。thread_id（返信と resolve に使う）、comment_id、path、severity、title、body
"""
import base64
import json
import re
import subprocess
import sys

MARKER = re.compile(r"<!-- claude-review-finding (\S+) -->")
NEW_COUNT = re.compile(r"found (\d+) new potential bug")

QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid
      reviews(last: 30) { nodes { author { login } body state commit { oid } submittedAt url } }
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated
          comments(first: 20) { nodes { databaseId body author { login } } }
        }
      }
    }
  }
}
"""


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def decode_marker(body):
    m = MARKER.search(body or "")
    if not m:
        return None
    try:
        return json.loads(base64.b64decode(m.group(1) + "==="))
    except (ValueError, json.JSONDecodeError):
        return {}


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo, number = sys.argv[1], int(sys.argv[2])
    owner, name = repo.split("/")
    data = json.loads(gh("api", "graphql", "-f", f"query={QUERY}", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={number}"))
    pr = data["data"]["repository"]["pullRequest"]
    head = pr["headRefOid"]

    runs = json.loads(gh("run", "list", "-R", repo, "--workflow", "pr-review.yml", "--commit", head, "--json", "status,conclusion,url,databaseId", "-L", "5"))
    running = [r for r in runs if r["status"] != "completed"]

    head_reviews = [r for r in pr["reviews"]["nodes"] if (r.get("commit") or {}).get("oid") == head and NEW_COUNT.search(r.get("body") or "")]
    latest = head_reviews[-1] if head_reviews else None
    new_count = int(NEW_COUNT.search(latest["body"]).group(1)) if latest else None

    threads = []
    for t in pr["reviewThreads"]["nodes"]:
        comments = t["comments"]["nodes"]
        if t["isResolved"] or not comments:
            continue
        meta = decode_marker(comments[0]["body"])
        if meta is None:
            continue
        body = MARKER.sub("", comments[0]["body"]).strip()
        threads.append({
            "thread_id": t["id"],
            "comment_id": comments[0]["databaseId"],
            "path": meta.get("path"),
            "line": meta.get("line"),
            "severity": meta.get("severity"),
            "title": meta.get("title"),
            "body": body,
            "replies": [c["body"] for c in comments[1:]],
            "outdated": t["isOutdated"],
        })

    if running or latest is None:
        state = "reviewing"
    elif threads:
        state = "has_findings"
    else:
        state = "clean"

    print(json.dumps({
        "state": state,
        "head": head,
        "workflow_runs": runs,
        "latest_review": {"url": latest["url"], "new_findings": new_count} if latest else None,
        "threads": threads,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
