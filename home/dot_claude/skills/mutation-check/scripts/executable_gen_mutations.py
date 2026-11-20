#!/usr/bin/env python3
"""差分で足した・変えた行に、決まった書き換えの表を機械的に当てて、変異の候補を JSON で出す。

使い方: gen_mutations.py --base <ref> [--out 候補.json] [パス...]
  作業ツリーのルートで実行する。<ref> からワーキングツリーまでの差分を見る。
  対象は Ruby（.rb / .rake）と JS / TS（.js / .jsx / .ts / .tsx）。テストのファイルは除く。

人が選ぶと「テストが拾えると知っている書き換え」に寄るので、演算子・真偽・数値・よく使うメソッドは
表から漏れなく作る。仕様に踏み込んだ変異（集計の取り違え、タイムゾーンなど）は別に足すこと。

  Ruby     Prism の構文木から作る（gen_mutations_ruby.rb）。
           Prism を読める ruby が無いか --no-ast のときは、下の JS / TS と同じ作り方に落ちる
  JS / TS  行の文字列に正規表現を当てる

どちらの変異も `offset`（ファイル先頭からのバイト位置）で場所を持つ。
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

RUBY = {".rb", ".rake"}
JS = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
TEST_FILE = re.compile(r"(^|/)(spec|test|tests|__tests__|e2e)/|_spec\.rb$|_test\.rb$|\.(test|spec|stories)\.[jt]sx?$")

# (名前, 正規表現, 置き換えの候補を返す関数)。文字列とコメントを伏せた行に当てる
COMMON = [
    ("比較", re.compile(r"(?<![=!<>])(===|!==|==|!=|>=|<=)(?![=>])"),
     lambda t: {"===": ["!=="], "!==": ["==="], "==": ["!="], "!=": ["=="], ">=": [">"], "<=": ["<"]}[t]),
    # 総称型や JSX のタグを拾わないよう、前後に空白のあるものだけ
    ("比較", re.compile(r"(?<= )[<>](?= )"), lambda t: [t + "="]),
    ("論理", re.compile(r"&&(?!=)|\|\|(?!=)"), lambda t: ["||" if t == "&&" else "&&"]),
    ("真偽", re.compile(r"(?<![\w.:@$])(true|false)(?![\w:?!])"), lambda t: ["false" if t == "true" else "true"]),
    ("数値", re.compile(r"(?<![\w.])\d+(?![\w.])"), lambda t: [str(int(t) + 1)]),
    ("算術", re.compile(r"(?<= )[-+*/](?= )"), lambda t: [{"+": "-", "-": "+", "*": "/", "/": "*"}[t]]),
    ("否定", re.compile(r"(?<![\w=!)\]])!(?=[\w(@$])"), lambda t: [""]),
]


def swap(pairs):
    return lambda t: [pairs[t]]


RUBY_OPS = [
    ("条件", re.compile(r"\b(if|unless)\b"), swap({"if": "unless", "unless": "if"})),
    ("述語", re.compile(r"\.(present|blank|any|none|all)\?"),
     lambda t: ["." + {"present": "blank", "blank": "present", "any": "none", "none": "any", "all": "any"}[t[1:-1]] + "?"]),
    ("取り出し", re.compile(r"\.(min|max|first|last|floor|ceil|select|reject)\b(?![?!_])"),
     lambda t: ["." + {"min": "max", "max": "min", "first": "last", "last": "first", "floor": "ceil",
                       "ceil": "floor", "select": "reject", "reject": "select"}[t[1:]]]),
    ("削除", re.compile(r"\.(uniq|compact|distinct)\b(?![?!_(])"), lambda t: [""]),
]
JS_OPS = [
    ("取り出し", re.compile(r"\.(some|every)\(|Math\.(min|max|floor|ceil)\b"),
     swap({".some(": ".every(", ".every(": ".some(", "Math.min": "Math.max", "Math.max": "Math.min",
           "Math.floor": "Math.ceil", "Math.ceil": "Math.floor"})),
]
# 行ごと消す: 早期に抜ける行（ガード節）
RUBY_GUARD = re.compile(r"^\s*(return|next|break)\b.*\b(if|unless)\b")
JS_GUARD = re.compile(r"^\s*if\s*\(.*\)\s*(return|continue|break)\b[^{]*;?\s*$")


def mask(line, ruby):
    """文字列の中身とコメントを同じ長さの空白にして返す（位置を元の行と揃えたまま、中を拾わないため）。"""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and i + 1 < len(line):
                out.append("  ")
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(c)
            else:
                out.append(" ")
        elif c in "\"'`":
            quote = c
            out.append(c)
        elif (ruby and c == "#") or (not ruby and line.startswith("//", i)):
            out.append(" " * (len(line) - i))
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def changed_lines(base, paths):
    """{ファイル: [足した・変えた行番号]} を返す。"""
    diff = subprocess.run(
        # 利用者の設定（接頭辞、外部の diff、パスの引用）でヘッダーの形が変わらないようにする
        ["git", "-c", "core.quotepath=false", "diff", "-U0", "--no-color", "--no-ext-diff",
         "--src-prefix=a/", "--dst-prefix=b/", "--diff-filter=AMR", base, "--", *paths],
        capture_output=True, text=True, check=True,
    ).stdout
    result, current, in_header = {}, None, False
    for row in diff.splitlines():
        if row.startswith("diff --git "):
            current, in_header = None, True
        elif in_header and row.startswith("+++ "):
            # ヘッダーの中だけで見る。`++ i` で始まる足した行も `+++ ` で始まるため
            current = row[6:] if row.startswith("+++ b/") else None
        elif row.startswith("@@") and current:
            in_header = False
            start, _, count = re.search(r"\+(\d+)(,(\d+))?", row).groups()
            result.setdefault(current, []).extend(range(int(start), int(start) + int(count or 1)))
    # git diff は未追跡のファイルを出さないので、全行を足した行として扱う
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "--", *paths],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    for file in untracked:
        try:
            result[file] = list(range(1, len(Path(file).read_bytes().splitlines()) + 1))
        except (OSError, UnicodeDecodeError):
            pass
    return result


def mutate_line(text, ruby):
    """(名前, 位置, 元の語, 書き換えた語) を返す。"""
    masked = mask(text, ruby)
    # 複数行のコメント（JSDoc）の途中と import は、行だけを見ても式ではないと分かる
    if not masked.strip() or (not ruby and re.match(r"\s*(/\*|\*|import\b)", text)):
        return
    if (RUBY_GUARD if ruby else JS_GUARD).search(masked):
        yield "行の削除", 0, text, ""
    for name, pattern, replacements in COMMON + (RUBY_OPS if ruby else JS_OPS):
        for found in pattern.finditer(masked):
            for new in replacements(found.group(0)):
                yield name, found.start(), found.group(0), new


def ruby_ast(targets):
    """Prism で作った変異を返す。Prism を読める ruby が無ければ None。"""
    script = Path(__file__).with_name("gen_mutations_ruby.rb")
    if not script.exists():  # リポジトリの中では chezmoi の接頭辞が付いている
        script = script.with_name("executable_" + script.name)
    try:
        available = subprocess.run(["ruby", "-rprism", "-e", "1"], capture_output=True).returncode == 0
    except OSError:
        available = False
    if not available:
        print("gen_mutations: Prism を読める ruby が無いので、Ruby も正規表現で作る", file=sys.stderr)
        return None
    # Prism があるのに落ちたときは正規表現に落とさない。作り方で候補が変わるので、気づかずに縮退させない
    result = subprocess.run(["ruby", str(script)], input=json.dumps(targets), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"gen_mutations: gen_mutations_ruby.rb が失敗した（--no-ast で正規表現に切り替えられる）\n{result.stderr.strip()}")
    return json.loads(result.stdout)["mutations"]


def generate(base, paths, use_ast=True):
    changed = {f: n for f, n in changed_lines(base, paths).items()
               if Path(f).suffix in RUBY | JS and not TEST_FILE.search(f)}
    mutations = []
    if use_ast:
        ruby = {f: n for f, n in changed.items() if Path(f).suffix in RUBY}
        from_ast = ruby_ast(ruby) if ruby else None
        if from_ast is not None:
            mutations += from_ast
            changed = {f: n for f, n in changed.items() if f not in ruby}
    for file, numbers in sorted(changed.items()):
        suffix = Path(file).suffix
        try:
            # 位置をバイトで数えるので、改行コードを変えずに読む
            lines = Path(file).read_bytes().decode().splitlines(keepends=True)
        except (OSError, UnicodeDecodeError):
            continue
        starts = [0]
        for line in lines:
            starts.append(starts[-1] + len(line.encode()))
        for number in numbers:
            text = lines[number - 1].rstrip("\r\n")
            for name, column, old, new in mutate_line(text, suffix in RUBY):
                shown = "行を消す" if name == "行の削除" else f"{old} → {new or '（消す）'}"
                mutations.append({
                    "label": f"auto/{name}: {file}:{number}:{column + 1} {shown}",
                    "file": file, "offset": starts[number - 1] + len(text[:column].encode()), "old": old, "new": new,
                })
    return mutations


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="差分の起点（例: git merge-base origin/main HEAD の結果）")
    parser.add_argument("--out", help="候補を書き出す先（無ければ標準出力）")
    parser.add_argument("--no-ast", action="store_true", help="Ruby も構文木を使わず正規表現で作る")
    parser.add_argument("paths", nargs="*", help="対象を絞るパス")
    args = parser.parse_args()
    try:
        mutations = generate(args.base, args.paths, use_ast=not args.no_ast)
    except subprocess.CalledProcessError as e:
        sys.exit(f"gen_mutations: git diff に失敗: {e.stderr.strip()}")
    text = json.dumps({"mutations": mutations}, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text)
        print(f"{len(mutations)} 件の候補を {args.out} に書いた")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
