#!/usr/bin/env python3
"""手で選んだ変異（コードの小さな書き換え）を 1 つずつ入れてテストを流し、変異ごとの結果を分ける。

使い方: run_mutations.py <定義.json> [--out 結果.json] [--only ラベルの接頭辞] [--survivors-of 前回の結果.json]
  作業ツリーのルートで実行する（定義の file はそこからの相対パス）。
  定義の書式は references/definition.md にある。

結果は次のどれかになる。
  killed   テストが落ちた（その変異を検出できる）
  survived テストが通った（生き残り。テストの穴か、結果が変わらない書き換え）
  broken   テストが実行されずに落ちた（構文が壊れた、読み込みで落ちた）。検出には数えない
  timeout  時間の上限を超えた
  invalid  定義の誤り（old が 1 回だけ現れる、を満たさない等）。コードを直して定義が古くなったときもこれになる

書き換えたファイルは、テストの成否や中断にかかわらず毎回元の内容に戻す。
"""
import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

# summary: テストが実行されたときに必ず出る集計の行。出なければ broken とみなす
# broken: 集計の行が出ていても、読み込みに失敗したファイルがあることを示す行
RUNNERS = {
    "rspec": {
        "summary": r"\d+ examples?, \d+ failures?",
        "broken": r"errors? occurred outside of examples",
    },
    "jest": {
        "summary": r"^Tests:\s+.*\d+ total",
        "broken": r"Test suite failed to run",
    },
    "vitest": {
        "summary": r"^\s*Tests\s+.*\(\d+\)",
        "broken": r"Failed Suites \d+",
    },
}
# 変異を入れない 1 回の上限。変異ごとの上限は、定義に無ければこの 1 回にかかった時間から決める
BASELINE_TIMEOUT = 600
MIN_TIMEOUT = float(os.environ.get("MUTATION_CHECK_MIN_TIMEOUT", 30))
LABELS = {
    "killed": "検出",
    "survived": "生き残り",
    "broken": "壊れた",
    "timeout": "時間切れ",
    "invalid": "定義の誤り",
}
NO_SUMMARY = "（集計の行なし）"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class DefinitionError(Exception):
    pass


def load_definition(path):
    try:
        definition = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise DefinitionError(f"定義を読めません: {e}")
    command = definition.get("command")
    if not (isinstance(command, list) and command and all(isinstance(c, str) for c in command)):
        raise DefinitionError("command は文字列の配列で書く")
    runner = definition.get("runner")
    if runner is not None and runner not in RUNNERS:
        raise DefinitionError(f"runner は {' / '.join(RUNNERS)} のどれか（他は summary_pattern を書く）")
    preset = RUNNERS.get(runner, {})
    summary = definition.get("summary_pattern", preset.get("summary"))
    if not summary:
        raise DefinitionError("runner か summary_pattern のどちらかが要る")
    broken = definition.get("broken_pattern", preset.get("broken"))
    mutations = definition.get("mutations")
    if not (isinstance(mutations, list) and mutations):
        raise DefinitionError("mutations が空")
    timeout = definition.get("timeout")
    if timeout is not None and not (isinstance(timeout, (int, float)) and not isinstance(timeout, bool) and timeout > 0):
        raise DefinitionError("timeout は 0 より大きい数で書く")
    seen = set()
    for i, m in enumerate(mutations):
        missing = [k for k in ("label", "file", "old", "new") if not isinstance(m.get(k), str)]
        if missing:
            raise DefinitionError(f"mutations[{i}] に {', '.join(missing)} が無い")
        if m["label"] in seen:
            raise DefinitionError(f"label が重複している: {m['label']}")
        seen.add(m["label"])
    try:
        return {
            "command": command,
            "timeout": timeout,
            "summary": re.compile(summary, re.M),
            "broken": re.compile(broken, re.M) if broken else None,
            "mutations": mutations,
        }
    except re.error as e:
        raise DefinitionError(f"正規表現が誤っている: {e}")


def run_tests(config, timeout):
    """(status, 集計の行, 秒) を返す。status は passed / killed / broken / timeout。集計の行が無ければ NO_SUMMARY。"""
    started = time.monotonic()
    # テストのコマンドがラッパー越しに子プロセスを作るので、上限を超えたらグループごと止める。
    # コンテナの中で動くテストまでは止められない
    proc = subprocess.Popen(
        config["command"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors="replace", start_new_session=True,
    )
    try:
        output, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return "timeout", f"{timeout:.0f} 秒を超えた", time.monotonic() - started
    except BaseException:
        kill_group(proc)
        raise
    seconds = time.monotonic() - started
    output = ANSI.sub("", output)
    found = config["summary"].search(output)
    summary = found.group(0).strip() if found else NO_SUMMARY
    if proc.returncode == 0:
        return "passed", summary, seconds
    if not found or (config["broken"] and config["broken"].search(output)):
        return "broken", summary, seconds
    return "killed", summary, seconds


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def apply_and_run(mutation, config):
    path = Path(mutation["file"])
    # 改行コードを変えずに戻せるよう、バイトのまま読み書きする
    try:
        original = path.read_bytes()
    except OSError as e:
        return "invalid", f"file を読めない: {e}", 0.0
    old, new = mutation["old"].encode(), mutation["new"].encode()
    if old == new:
        return "invalid", "old と new が同じ", 0.0
    if "offset" in mutation:
        # 機械的に作った変異は同じ書き方が何か所もあるので、位置（バイト）で場所を決める
        offset = mutation["offset"]
        if not (isinstance(offset, int) and offset >= 0 and original[offset:offset + len(old)] == old):
            return "invalid", f"offset {offset} の中身が old と違う（コードを直して定義が古くなった）", 0.0
    else:
        count = original.count(old)
        if count != 1:
            return "invalid", f"old が {count} 回見つかった（ちょうど 1 回にする）", 0.0
        offset = original.index(old)
    try:
        path.write_bytes(original[:offset] + new + original[offset + len(old):])
        status, summary, seconds = run_tests(config, config["timeout"])
    finally:
        path.write_bytes(original)
    return ("survived" if status == "passed" else status), summary, seconds


def select(mutations, only, survivors_of):
    if survivors_of:
        previous = json.loads(Path(survivors_of).read_text())
        survived = {r["label"] for r in previous["results"] if r["status"] == "survived"}
        mutations = [m for m in mutations if m["label"] in survived]
    return [m for m in mutations if m["label"].startswith(only)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("definition")
    parser.add_argument("--out", help="結果を JSON で書き出す先")
    parser.add_argument("--only", default="", help="label がこの接頭辞で始まる変異だけを流す")
    parser.add_argument("--survivors-of", help="前回の結果（--out）で生き残った変異だけを流す")
    args = parser.parse_args()

    try:
        config = load_definition(args.definition)
        mutations = select(config["mutations"], args.only, args.survivors_of)
    except (DefinitionError, OSError, KeyError, json.JSONDecodeError) as e:
        sys.exit(f"run_mutations: {e}")
    if not mutations:
        sys.exit("run_mutations: 流す変異が無い")

    # kill されたときや端末を閉じられたときも finally でファイルを戻せるよう、シグナルを例外に変える
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(number, lambda n, _: sys.exit(128 + n))

    status, summary, seconds = run_tests(config, config["timeout"] or BASELINE_TIMEOUT)
    print(f"基準: {summary}（{seconds:.0f} 秒）", flush=True)
    if status != "passed":
        sys.exit("run_mutations: 変異を入れる前にテストが通っていないので止めます")
    if summary == NO_SUMMARY:
        # 集計の行を拾えないと、検出と「壊れた」を分けられない
        sys.exit("run_mutations: 基準の出力に集計の行が無い。runner か summary_pattern を直す")

    if config["timeout"] is None:
        # 条件式や算術の書き換えは無限ループを作りやすい。固定の長い上限だと 1 件ごとに待たされる
        config["timeout"] = max(MIN_TIMEOUT, seconds * 3)

    def write_out(counts=None):
        if args.out:
            Path(args.out).write_text(
                json.dumps({"counts": counts, "results": results}, ensure_ascii=False, indent=2) + "\n")

    results = []
    for mutation in mutations:
        status, summary, seconds = apply_and_run(mutation, config)
        results.append({
            "label": mutation["label"], "file": mutation["file"],
            "status": status, "summary": summary, "seconds": round(seconds, 1),
        })
        print(f"[{LABELS[status]}] {mutation['label']}: {summary}（{seconds:.0f} 秒）", flush=True)
        # 途中で止められても、そこまでの結果を --survivors-of に使えるように毎回書く
        write_out()

    counts = {s: sum(1 for r in results if r["status"] == s) for s in LABELS}
    # 壊れた変異や時間切れを検出に数えると、テストが実際より強く見えるので分母からも外す
    valid = counts["killed"] + counts["survived"]
    print(f"\n検出 {counts['killed']} / {valid}"
          + "".join(f"、{LABELS[s]} {counts[s]}" for s in ("broken", "timeout", "invalid") if counts[s]))
    for r in results:
        if r["status"] != "killed":
            print(f"- [{LABELS[r['status']]}] {r['label']}: {r['summary']}")
    write_out(counts)


if __name__ == "__main__":
    main()
