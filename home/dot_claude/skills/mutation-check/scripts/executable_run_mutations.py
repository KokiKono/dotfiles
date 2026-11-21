#!/usr/bin/env python3
"""手で選んだ変異（コードの小さな書き換え）を 1 つずつ入れてテストを流し、変異ごとの結果を分ける。

使い方: run_mutations.py <定義.json> [--out 結果.json] [--only ラベルの接頭辞] [--survivors-of 前回の結果.json] [--no-cache]
        run_mutations.py --clear-cache
  作業ツリーのルートで実行する（定義の file はそこからの相対パス）。
  定義の書式は references/definition.md にある。

定義に tests（変異ごとに流すテストのファイル）があれば、結果をキャッシュする。変異を入れた後のソースと
テストのファイルが前と同じ変異は流さず、前の結果を返す。置き場は ~/.cache/mutation-check/cache.sqlite3
（MUTATION_CHECK_CACHE で差し替えられる）。

結果は次のどれかになる。
  killed   テストが落ちた（その変異を検出できる）
  survived テストが通った（生き残り。テストの穴か、結果が変わらない書き換え）
  broken   テストが実行されずに落ちた（構文が壊れた、読み込みで落ちた）。検出には数えない
  timeout  時間の上限を超えた
  invalid  定義の誤り（old が 1 回だけ現れる、を満たさない等）。コードを直して定義が古くなったときもこれになる

書き換えたファイルは、テストの成否や中断にかかわらず毎回元の内容に戻す。
"""
import argparse
import hashlib
import json
import os
import re
import signal
import sqlite3
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
# 結果の見分け方（集計の行の扱いなど）を変えたら上げる。鍵に入るので、古い結果が全部外れる
CACHE_VERSION = 1
CACHE_DAYS = 30
CACHED = ("killed", "survived")


class DefinitionError(Exception):
    pass


def cache_path():
    override = os.environ.get("MUTATION_CHECK_CACHE")
    if override:
        return Path(override)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "mutation-check" / "cache.sqlite3"


class Cache:
    """変異の結果を、変異を入れた後のソースとテストのファイルの中身で引く。

    results.key はソースの側（コマンド、見分け方、ファイル名、変異を入れた後の中身、同じテストで
    確かめている他の変異対象のファイルの中身）のハッシュ。
    label や行番号は入れないので、同じ書き換えなら名前や位置が変わっても当たる。
    テストの側は results.tests に {パス: 中身のハッシュ} で持ち、引くときに今の中身と比べる。
    鍵に入れないのは、テストに行を足しただけなら「検出」をそのまま使えるようにするため。
    """

    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        # 並行するセッションが同じファイルに書くので、1 文ごとに確定し、ロックは待つ
        self.db = sqlite3.connect(path, timeout=30, isolation_level=None)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS results (
                key TEXT PRIMARY KEY, status TEXT NOT NULL, summary TEXT NOT NULL,
                label TEXT NOT NULL, tests TEXT NOT NULL, at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS tests (sha TEXT PRIMARY KEY, lines TEXT NOT NULL, at INTEGER NOT NULL);
        """)
        self.now = int(time.time())
        self.saved = set()

    def key(self, config, mutation, mutated):
        digest = hashlib.sha256()
        broken = config["broken"].pattern if config["broken"] else ""
        parts = [str(CACHE_VERSION), json.dumps(config["command"]), config["summary"].pattern, broken, mutation["file"]]
        for other in mutation["with"]:
            # 同じ PR で直している呼び出し先を変えたら、こちらの変異の結果も変わりうる
            try:
                parts += [other, hashlib.sha256(Path(other).read_bytes()).hexdigest()]
            except OSError:
                parts += [other, ""]
        for part in parts:
            digest.update(part.encode() + b"\0")
        digest.update(mutated)
        return digest.hexdigest()

    def fingerprint(self, tests):
        """{パス: 中身のハッシュ}。行ごとのハッシュも残し、後で「行を足しただけか」を比べられるようにする。

        数十分かかる実行の途中でテストを直されることがあるので、ハッシュは覚えずに毎回読み直す。
        """
        result = {}
        for test in tests:
            content = Path(test).read_bytes()
            sha = result[test] = hashlib.sha256(content).hexdigest()
            if sha in self.saved:
                continue
            # テストの中身そのものは持たない（業務のコードなので）。行の並びを比べられれば足りる
            lines = "\n".join(hashlib.sha1(line).hexdigest()[:12] for line in content.splitlines())
            self.db.execute("INSERT INTO tests VALUES (?, ?, ?) ON CONFLICT(sha) DO UPDATE SET at = excluded.at",
                            (sha, lines, self.now))
            self.saved.add(sha)
        return result

    def only_added(self, old_sha, new_sha):
        if old_sha == new_sha:
            return True
        rows = dict(self.db.execute("SELECT sha, lines FROM tests WHERE sha IN (?, ?)", (old_sha, new_sha)))
        if old_sha not in rows:
            return False
        rest = iter(rows[new_sha].split("\n"))
        return all(line in rest for line in rows[old_sha].split("\n"))

    def lookup(self, key, tests):
        """(status, 集計の行, テストが記録したときと同じか) か None。"""
        row = self.db.execute("SELECT status, summary, tests FROM results WHERE key = ?", (key,)).fetchone()
        if not row:
            return None
        status, summary, before = row[0], row[1], json.loads(row[2])
        now = self.fingerprint(tests)
        if before != now:
            # テストに行やファイルを足しても、落ちていたテストは落ちたままなので「検出」は使える。
            # 生き残りは足したテストで検出に変わりうるので流し直す。足した行が既存のテストを弱めた場合
            # （前処理に足した、skip を足した、囲んで無効にした）は見逃す（--no-cache で流し直せる）
            if status != "killed" or not all(t in now and self.only_added(sha, now[t]) for t, sha in before.items()):
                return None
        self.db.execute("UPDATE results SET tests = ?, at = ? WHERE key = ?", (json.dumps(now), self.now, key))
        return status, summary, before == now

    def store(self, key, status, summary, label, fingerprint):
        self.db.execute("INSERT OR REPLACE INTO results VALUES (?, ?, ?, ?, ?, ?)",
                        (key, status, summary, label, json.dumps(fingerprint), self.now))

    def sweep(self):
        cutoff = self.now - CACHE_DAYS * 86400
        self.db.execute("DELETE FROM results WHERE at < ?", (cutoff,))
        self.db.execute("DELETE FROM tests WHERE at < ?", (cutoff,))


def load_tests(definition, mutations):
    """変異ごとのテストのファイルを mutation["tests"] に、同じテストで確かめている他の変異対象の
    ファイルを mutation["with"] に入れる。定義に tests が無ければ、どの変異も空になる。"""
    tests = definition.get("tests")
    if tests is None:
        for m in mutations:
            m["tests"], m["with"] = (), ()
        return
    by_file = {"*": tests} if isinstance(tests, list) else tests
    if not isinstance(by_file, dict):
        raise DefinitionError("tests は配列か、変異するファイルごとの配列で書く")
    for name, files in by_file.items():
        if not (isinstance(files, list) and files and all(isinstance(f, str) for f in files)):
            raise DefinitionError(f"tests の {name} は空でない文字列の配列で書く")
        missing = [f for f in files if not Path(f).is_file()]
        if missing:
            raise DefinitionError(f"tests のファイルが無い: {', '.join(missing)}")
    for m in mutations:
        files = by_file.get(m["file"], by_file.get("*"))
        if files is None:
            raise DefinitionError(f"tests に {m['file']} の分が無い（どのファイルにも流すものは \"*\" に書く）")
        m["tests"] = tuple(files)
    of_file = {m["file"]: set(m["tests"]) for m in mutations}
    for m in mutations:
        m["with"] = tuple(sorted(f for f, files in of_file.items() if f != m["file"] and files & of_file[m["file"]]))


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
    load_tests(definition, mutations)
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


def run_tests(config, tests, timeout):
    """(status, 集計の行, 秒) を返す。status は passed / killed / broken / timeout。集計の行が無ければ NO_SUMMARY。"""
    started = time.monotonic()
    # テストのコマンドがラッパー越しに子プロセスを作るので、上限を超えたらグループごと止める。
    # コンテナの中で動くテストまでは止められない
    proc = subprocess.Popen(
        config["command"] + list(tests), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
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


def mutate(mutation):
    """(元の中身, 変異を入れた中身) を返す。定義が誤っていれば DefinitionError。"""
    # 改行コードを変えずに戻せるよう、バイトのまま読み書きする
    try:
        original = Path(mutation["file"]).read_bytes()
    except OSError as e:
        raise DefinitionError(f"file を読めない: {e}")
    old, new = mutation["old"].encode(), mutation["new"].encode()
    if old == new:
        raise DefinitionError("old と new が同じ")
    if "offset" in mutation:
        # 機械的に作った変異は同じ書き方が何か所もあるので、位置（バイト）で場所を決める
        offset = mutation["offset"]
        if not (isinstance(offset, int) and offset >= 0 and original[offset:offset + len(old)] == old):
            raise DefinitionError(f"offset {offset} の中身が old と違う（コードを直して定義が古くなった）")
    else:
        count = original.count(old)
        if count != 1:
            raise DefinitionError(f"old が {count} 回見つかった（ちょうど 1 回にする）")
        offset = original.index(old)
    return original, original[:offset] + new + original[offset + len(old):]


def apply_and_run(mutation, original, mutated, config, timeout):
    path = Path(mutation["file"])
    try:
        path.write_bytes(mutated)
        status, summary, seconds = run_tests(config, mutation["tests"], timeout)
    finally:
        path.write_bytes(original)
    return ("survived" if status == "passed" else status), summary, seconds


def open_cache(mutations):
    if not mutations[0]["tests"]:
        # command に埋めたテストのファイルは見分けられない。テストを変えても気づけないので使わない
        return None
    try:
        return Cache(cache_path())
    except (OSError, sqlite3.Error) as e:
        print(f"run_mutations: キャッシュを開けないので使わずに流す: {e}", file=sys.stderr)
        return None


def clear_cache():
    path = cache_path()
    for suffix in ("", "-journal"):
        Path(f"{path}{suffix}").unlink(missing_ok=True)
    print(f"キャッシュを消した: {path}")


def select(mutations, only, survivors_of):
    if survivors_of:
        previous = json.loads(Path(survivors_of).read_text())
        survived = {r["label"] for r in previous["results"] if r["status"] == "survived"}
        mutations = [m for m in mutations if m["label"] in survived]
    return [m for m in mutations if m["label"].startswith(only)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("definition", nargs="?")
    parser.add_argument("--out", help="結果を JSON で書き出す先")
    parser.add_argument("--only", default="", help="label がこの接頭辞で始まる変異だけを流す")
    parser.add_argument("--survivors-of", help="前回の結果（--out）で生き残った変異だけを流す")
    parser.add_argument("--no-cache", action="store_true",
                        help="キャッシュを引かずに全部流す（結果は記録する）。tests に無いファイルを変えたときに使う")
    parser.add_argument("--clear-cache", action="store_true", help="キャッシュを消して終わる")
    args = parser.parse_args()
    if args.clear_cache:
        return clear_cache()
    if not args.definition:
        parser.error("定義のファイルが要る")

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

    cache = open_cache(mutations)
    timeouts = {}

    def cached(method, *method_args):
        """キャッシュを呼ぶ。不調（ディスクが一杯、ロックが取れない）なら、以降は使わずに流す。"""
        nonlocal cache
        if not cache:
            return None
        try:
            return getattr(cache, method)(*method_args)
        except (OSError, sqlite3.Error) as e:
            print(f"run_mutations: キャッシュが使えなくなったので、以降は使わずに流す: {e}", file=sys.stderr)
            cache = None
            return None

    def baseline(tests):
        """変異を入れずに 1 回流し、変異ごとの上限を決める。テストの組ごとに 1 回。"""
        if tests in timeouts:
            return
        status, summary, seconds = run_tests(config, tests, config["timeout"] or BASELINE_TIMEOUT)
        print(f"基準{'（' + ' '.join(tests) + '）' if tests else ''}: {summary}（{seconds:.0f} 秒）", flush=True)
        if status != "passed":
            sys.exit("run_mutations: 変異を入れる前にテストが通っていないので止めます")
        if summary == NO_SUMMARY:
            # 集計の行を拾えないと、検出と「壊れた」を分けられない
            sys.exit("run_mutations: 基準の出力に集計の行が無い。runner か summary_pattern を直す")
        # 条件式や算術の書き換えは無限ループを作りやすい。固定の長い上限だと 1 件ごとに待たされる
        timeouts[tests] = config["timeout"] or max(MIN_TIMEOUT, seconds * 3)

    def write_out(counts=None, **totals):
        if args.out:
            body = {"counts": counts, "results": results, **totals}
            Path(args.out).write_text(json.dumps(body, ensure_ascii=False, indent=2) + "\n")

    def run(mutation, original, mutated):
        tests = mutation["tests"]
        # 流している間にテストや他の変異対象を直されたら、どの中身で出た結果か分からないので記録しない
        before = cached("key", config, mutation, mutated), cached("fingerprint", tests)
        status, summary, seconds = apply_and_run(mutation, original, mutated, config, timeouts[tests])
        # 壊れた・時間切れは環境や定義の不備でも起きるので、次も流す
        if status in CACHED and all(before) and before == (cached("key", config, mutation, mutated), cached("fingerprint", tests)):
            cached("store", before[0], status, summary, mutation["label"], before[1])
        return status, summary, seconds

    # 先に全部の変異をキャッシュに当て、流す必要のあるテストの組の基準をまとめて流す。
    # 変異を流し始めてから別の組の基準が落ちると、そこまでの数十分が無駄になる
    plans = []
    for mutation in mutations:
        try:
            original, mutated = mutate(mutation)
        except DefinitionError as e:
            plans.append((mutation, None, str(e)))
            continue
        hit = None
        if not args.no_cache:
            key = cached("key", config, mutation, mutated)
            hit = key and cached("lookup", key, mutation["tests"])
        plans.append((mutation, hit, (original, mutated)))
    for mutation, hit, sources in plans:
        # テストを足した後の「検出」の使い回しでも、足したテストが変異を入れないコードで通ることは確かめる
        if isinstance(sources, tuple) and not (hit and hit[2]):
            baseline(mutation["tests"])

    results = []
    for mutation, hit, sources in plans:
        if hit:
            status, summary, seconds = hit[0], hit[1], 0.0
        elif isinstance(sources, str):
            status, summary, seconds = "invalid", sources, 0.0
        else:
            status, summary, seconds = run(mutation, *sources)
        result = {
            "label": mutation["label"], "file": mutation["file"],
            "status": status, "summary": summary, "seconds": round(seconds, 1),
        }
        if hit:
            result["cached"] = True
        results.append(result)
        took = "キャッシュ" if hit else f"{seconds:.0f} 秒"
        print(f"[{LABELS[status]}] {mutation['label']}: {summary}（{took}）", flush=True)
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
    if mutations[0]["tests"]:
        hits = sum(1 for r in results if r.get("cached"))
        print(f"キャッシュから {hits} 件、流したのは {len(results) - hits} 件")
        cached("sweep")
        write_out(counts, cached=hits)
    else:
        write_out(counts)


if __name__ == "__main__":
    main()
