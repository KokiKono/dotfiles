#!/usr/bin/env python3
"""pr-review-status.py <owner/repo> <PR 番号>

claude-review（.github/workflows/pr-review.yml）のレビュー状況と、bot が付けた i18n の警告を JSON で出す。

- state
  - "reviewing": 今の head に対するレビューがまだ終わっていない（workflow が実行中・待ち、またはレビュー未投稿）
  - "clean": 今の head へのレビューが「0 new」で、未解決の指摘スレッドも i18n の警告スレッドも無い。ループを終えてよい
  - "has_findings": 未解決の指摘か i18n の警告スレッドがある。threads / i18n を見て直すか返信する
- draft / labels: PR の状態。claude-review は draft だと claude-review ラベルが付くまで走らない
- threads: 未解決の claude-review 指摘。thread_id（返信と resolve に使う）、comment_id、path、severity、title、body
- i18n: bot が付けた i18n の警告。kind が "thread" なら未解決のレビューコメント、"comment" なら PR への普通のコメント。
  普通のコメントは「解決済み」を持たないので state には数えない

i18n の警告の拾い方は ~/.claude/pr-followup.local.json（PR_FOLLOWUP_CONFIG で差し替え可）で絞れる。
  i18n_bots: bot の login の配列。空なら bot すべて
  i18n_pattern: 本文に当てる正規表現（大文字小文字を区別しない）
"""
import base64
import json
import os
import re
import subprocess
import sys

MARKER = re.compile(r"<!-- claude-review(?:-schema)?-finding (\S+) -->")
NEW_COUNT = re.compile(r"found (\d+) new potential bug")
DEFAULT_I18N_PATTERN = r"i18n|translat|翻訳|locale|ロケール"

QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid isDraft
      labels(first: 30) { nodes { name } }
      reviews(last: 30) { nodes { author { login } body state commit { oid } submittedAt url } }
      comments(last: 50) { nodes { databaseId body url isMinimized author { login __typename } } }
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated
          comments(first: 20) { nodes { databaseId body path url author { login __typename } } }
        }
      }
    }
  }
}
"""


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def load_config():
    path = os.environ.get("PR_FOLLOWUP_CONFIG", os.path.expanduser("~/.claude/pr-followup.local.json"))
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


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
    config = load_config()
    i18n_bots = set(config.get("i18n_bots") or [])
    i18n_pattern = re.compile(config.get("i18n_pattern") or DEFAULT_I18N_PATTERN, re.IGNORECASE)

    def is_i18n_warning(comment):
        author = comment.get("author") or {}
        if author.get("__typename") != "Bot" or (i18n_bots and author.get("login") not in i18n_bots):
            return False
        return bool(i18n_pattern.search(comment.get("body") or ""))

    def i18n_entry(kind, comment, **extra):
        return {
            "kind": kind,
            "comment_id": comment["databaseId"],
            "author": comment["author"]["login"],
            "body": comment["body"],
            "url": comment["url"],
            **extra,
        }

    data = json.loads(gh("api", "graphql", "-f", f"query={QUERY}", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={number}"))
    pr = data["data"]["repository"]["pullRequest"]
    head = pr["headRefOid"]

    runs = json.loads(gh("run", "list", "-R", repo, "--workflow", "pr-review.yml", "--commit", head, "--json", "status,conclusion,url,databaseId", "-L", "5"))
    running = [r for r in runs if r["status"] != "completed"]

    head_reviews = [
        (r, int(m.group(1)))
        for r in pr["reviews"]["nodes"]
        if (r.get("commit") or {}).get("oid") == head and (m := NEW_COUNT.search(r.get("body") or ""))
    ]
    latest, new_count = head_reviews[-1] if head_reviews else (None, None)

    threads, i18n = [], []
    for t in pr["reviewThreads"]["nodes"]:
        comments = t["comments"]["nodes"]
        if t["isResolved"] or not comments:
            continue
        first = comments[0]
        meta = decode_marker(first["body"])
        if meta is None:
            # claude-review の指摘でなければ、bot の i18n 警告かどうかだけを見る
            if is_i18n_warning(first):
                i18n.append(i18n_entry("thread", first, thread_id=t["id"], path=first.get("path"), outdated=t["isOutdated"]))
            continue
        body = MARKER.sub("", first["body"]).strip()
        threads.append({
            "thread_id": t["id"],
            "comment_id": first["databaseId"],
            "path": meta.get("path"),
            "line": meta.get("line"),
            "severity": meta.get("severity"),
            "title": meta.get("title"),
            "body": body,
            "replies": [c["body"] for c in comments[1:]],
            "outdated": t["isOutdated"],
        })

    for c in pr["comments"]["nodes"]:
        if not c["isMinimized"] and is_i18n_warning(c):
            i18n.append(i18n_entry("comment", c))

    if running or latest is None:
        state = "reviewing"
    elif threads or any(w["kind"] == "thread" for w in i18n):
        state = "has_findings"
    else:
        state = "clean"

    print(json.dumps({
        "state": state,
        "head": head,
        "draft": pr["isDraft"],
        "labels": [l["name"] for l in pr["labels"]["nodes"]],
        "workflow_runs": runs,
        "latest_review": {"url": latest["url"], "new_findings": new_count} if latest else None,
        "threads": threads,
        "i18n": i18n,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
