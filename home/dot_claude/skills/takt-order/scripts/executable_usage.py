#!/usr/bin/env python3
"""usage.py <run ディレクトリ>

takt の run 1 回分について、step ごとの所要・モデル・トークン量を Markdown の表で出す。

takt のログ（logs/*.jsonl）には所要とモデルしか残らないので、トークン量は claude-headless が
残す claude のセッション記録（<claude 設定>/projects/<worktree を - で潰した名前>/*.jsonl）から取る。
takt は同じ persona のセッションを step をまたいで使い回すため、セッション単位ではなく
メッセージの時刻を phase の時間帯に当てて振り分ける。並列 step（レビュアー）は時間帯が重なるので、
セッションの最初のプロンプトに出てくる step 名で見分ける。
"""
import glob
import json
import os
import re
import sys
from datetime import datetime


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def fmt_dur(sec):
    sec = int(sec)
    return f"{sec // 60}m{sec % 60:02d}s"


def fmt_tok(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}k"
    return str(n)


TOKENS = {"in": "input_tokens", "cw": "cache_creation_input_tokens", "cr": "cache_read_input_tokens", "out": "output_tokens"}


def add_usage(acc, u):
    for k, f in TOKENS.items():
        acc[k] += u.get(f) or 0
    acc["calls"] += 1


def empty():
    return {"models": set(), **dict.fromkeys(TOKENS, 0), "calls": 0}


def tok_cells(a):
    return " | ".join(fmt_tok(a[k]) for k in TOKENS)


def short_model(m):
    return re.sub(r"^claude-|-\d+(-\d+)*$", "", m or "?")


def load_jsonl(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    run = os.path.abspath(sys.argv[1])
    meta = json.load(open(os.path.join(run, "meta.json"), encoding="utf-8"))
    run_start = ts(meta["startTime"])
    run_end = ts(meta.get("endTime") or meta["updatedAt"])

    # run は <worktree>/.takt/runs/<slug>
    worktree = os.path.dirname(os.path.dirname(os.path.dirname(run)))
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
    project_dir = os.path.join(claude_dir, "projects", re.sub(r"[^A-Za-z0-9]", "-", worktree))
    if not os.path.isdir(project_dir):
        print(f"usage.py: セッション記録が見つかりません: {project_dir}", file=sys.stderr)
        return 1

    phases = {}
    for e in load_jsonl(glob.glob(os.path.join(run, "logs", "*.jsonl"))[0]):
        if e["type"] == "phase_start":
            k = e["phaseExecutionId"]
            phases[k] = {"step": e["step"], "it": e.get("iteration"), "s": ts(e["timestamp"]), "e": None}
        elif e["type"] == "phase_complete" and e.get("phaseExecutionId") in phases:
            phases[e["phaseExecutionId"]]["e"] = ts(e["timestamp"])
    step_names = {p["step"] for p in phases.values()}

    # headless（entrypoint: sdk-cli）のセッションのうち、run の時間内のメッセージだけ拾う
    msgs, session_step = [], {}
    for path in glob.glob(os.path.join(project_dir, "*.jsonl")):
        if os.path.getmtime(path) < run_start - 5:  # run より前に書き終わったセッションは読まない
            continue
        sid = os.path.basename(path)
        by_id, headless, first_prompt = {}, False, None
        for o in load_jsonl(path):
            headless = headless or o.get("entrypoint") == "sdk-cli"
            if o.get("type") == "user" and first_prompt is None:
                first_prompt = json.dumps(o.get("message", {}).get("content"), ensure_ascii=False)[:20000]
            m = o.get("message") or {}
            if o.get("type") == "assistant" and m.get("usage") and o.get("timestamp"):
                t = ts(o["timestamp"])
                if run_start - 5 <= t <= run_end + 5:
                    by_id[m.get("id")] = (t, m.get("model"), m["usage"])  # 1 応答が複数行に分かれるので id で畳む
        if not headless or not by_id:
            continue
        hits = sorted((n for n in step_names if first_prompt and f"{n}.md" in first_prompt), key=len, reverse=True)
        if hits:
            session_step[sid] = hits[0]
        msgs += [(t, model, u, sid) for t, model, u in by_id.values()]

    agg, by_model = {}, {}
    for t, model, u, sid in msgs:
        hits = [k for k, p in phases.items() if p["s"] - 1 <= t <= (p["e"] or run_end) + 1]
        if len(hits) > 1:
            hits = [k for k in hits if phases[k]["step"] == session_step.get(sid)] or hits
        key = (phases[hits[0]]["it"], phases[hits[0]]["step"]) if hits else (None, "（step 外: takt 内部の selector など）")
        a = agg.setdefault(key, empty())
        a["models"].add(short_model(model))
        add_usage(a, u)
        add_usage(by_model.setdefault(short_model(model), empty()), u)

    span = {}
    for p in phases.values():
        key = (p["it"], p["step"])
        s, e = span.get(key, (float("inf"), 0))
        span[key] = (min(s, p["s"]), max(e, p["e"] or p["s"]))

    run_dur = fmt_dur(run_end - run_start)
    keys = sorted(set(span) | set(agg), key=lambda k: span.get(k, (float("inf"),))[0])
    print(f"run: {os.path.basename(run)} / status: {meta.get('status')} / 所要: {run_dur} / iterations: {meta.get('iterations')}")
    print()
    print("| iter | step | モデル | 所要 | input | cache write | cache read | output | 呼び出し |")
    print("|---|---|---|---|---|---|---|---|---|")
    total = empty()
    for k in keys:
        a = agg.get(k, empty())
        dur = fmt_dur(span[k][1] - span[k][0]) if k in span else "-"
        it = k[0] if k[0] is not None else "-"
        print(f"| {it} | {k[1]} | {', '.join(sorted(a['models'])) or '-'} | {dur} | {tok_cells(a)} | {a['calls']} |")
        for x in (*TOKENS, "calls"):
            total[x] += a[x]
    print(f"| | **合計** | | **{run_dur}** | {tok_cells(total)} | {total['calls']} |")

    print()
    print("| モデル | input | cache write | cache read | output |")
    print("|---|---|---|---|---|")
    for m, b in sorted(by_model.items()):
        print(f"| {m} | {tok_cells(b)} |")
    print()
    print("- 所要は step の各 phase（execute・report・judge）の最初から最後まで。並列 step は時間が重なるので、合計（run 全体）は各行の和にならない")
    print(f"- トークンは {project_dir} の headless セッションを集計。同じ worktree で takt を同時に 2 本流すと混ざる")
    return 0


if __name__ == "__main__":
    sys.exit(main())
