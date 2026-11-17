#!/usr/bin/env python3
"""Stop hook: 最後の返答が英語なら止めて、日本語で書き直させる。

settings.json の language と rules/writing.md で指示しても英語の返答が続き、
ユーザーが「日本語で」と送り直していた。指示を足しても効かなかったので、送り直しを hook に任せる。
"""
import json
import os
import re
import sys

KANA = re.compile(r"[぀-ヿ]")
JA_CHAR = re.compile(r"[぀-ヿ一-鿿]")
EN_CHAR = re.compile(r"[A-Za-z]")
# 英字がこの割合以上なら英語の返答とみなす。行に 1 つでも英文があれば止める判定は、
# 日本語の返答に混じる英語のログやタイトルで止まりすぎた
EN_RATIO = 0.9
# 英単語が空白で 4 つ続けば英文とみなす。パスや識別子だけの行は空白を挟まないので当たらない。
# 3 語だと PR の署名（Generated with AI）のような定型句まで拾う
ENGLISH = re.compile(r"[A-Za-z][A-Za-z'’]+(?:[ \t]+[A-Za-z][A-Za-z'’,.]*){3,}")
# 中にコードブロックを含めるための 4 連以上のバッククォートも、同じ数で閉じる。
# 行頭に限るのは、文中で ``` に触れただけで以降が丸ごと消えないようにするため
CODE_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,}).*?(?:^ {0,3}\1|\Z)", re.S | re.M)
# 見出しや太字だけの行は PR や issue の英語の題を写していることが多いので、冒頭の行の判定に使わない
TITLE_LINE = re.compile(r"\s*(#|\*\*.*\*\*\s*$)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
# リンク名は外部資料の英語のタイトルをそのまま写していることが多い
MD_LINK = re.compile(r"\[[^\]\n]*\]\([^)\s]*\)")
URL = re.compile(r"https?://\S+")
# 英文の中で画面の文言などを「」で引用していることがあり、そのかなで日本語と判定しないように除く
JA_QUOTE = re.compile(r"「[^」\n]*」|『[^』\n]*』")

# 英訳や英語の PR 本文など、英語で書くよう頼まれたときは止めない。
# 「英語」「英語に」だけで当てると「英語になってる」のような苦情まで通してしまう。
# translate も語として当てないと translateText のような識別子に当たる
ASKED_ENGLISH = re.compile(
    r"英訳|英語に(訳|直|して)|英語で(書いて|お願い)|英語版|\bin English\b|\btranslate (this|it|into|to)\b",
    re.I,
)
# ターンの途中にハーネスが差し込む user 行。ユーザーの入力ではないのでターンの区切りにしない
INJECTED = ("<task-notification", "<system-reminder")

REASON = (
    "このターンの返答に英語で書いた部分がありました。その部分を日本語で書き直してください"
    "（コード・識別子・引用する出力は原文のままでよい）。"
)


def prose(text):
    text = CODE_FENCE.sub("", text)
    text = INLINE_CODE.sub("", text)
    text = MD_LINK.sub("", text)
    text = URL.sub("", text)
    return JA_QUOTE.sub("", text)


def is_english(text):
    # 引用（>）は英語の出力の写し、表（|）は英訳文や店舗名などのデータであることが多い
    lines = [
        l for l in prose(text).splitlines()
        if l.strip() and not l.lstrip().startswith((">", "|"))
    ]
    if not lines:
        return False
    # 英語で書き出して日本語の草稿を貼る返答は割合では拾えないので、冒頭の行も見る
    first = next((l for l in lines if not TITLE_LINE.match(l)), "")
    if not KANA.search(first) and ENGLISH.search(first):
        return True
    body = "\n".join(lines)
    en = len(EN_CHAR.findall(body))
    ja = len(JA_CHAR.findall(body))
    return ENGLISH.search(body) is not None and en >= (en + ja) * EN_RATIO


def reversed_lines(path, chunk=1 << 20):
    # 毎ターン走るので先頭からは読まない。長いセッションのトランスクリプトは数百 MB になる
    with open(path, "rb") as f:
        pos = f.seek(0, os.SEEK_END)
        rest = b""
        while pos > 0:
            size = min(chunk, pos)
            pos -= size
            f.seek(pos)
            lines = (f.read(size) + rest).split(b"\n")
            rest = lines.pop(0)
            yield from reversed(lines)
        yield rest


def text_blocks(content):
    return [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]


def prompt_text(row):
    """ユーザーが入力した行ならその本文を、そうでなければ None を返す。"""
    if row.get("type") != "user" or row.get("isMeta"):
        return None
    # 要約より前は別の文脈なのでターンの区切りにするが、要約の本文は入力として扱わない
    if row.get("isCompactSummary"):
        return ""
    content = (row.get("message") or {}).get("content")
    if isinstance(content, str):
        return None if content.lstrip().startswith(INJECTED) else content
    # 画像を貼った入力は text と image のブロックのリストになる。tool_result だけのリストはツールの結果
    if isinstance(content, list) and text_blocks(content):
        return "\n".join(text_blocks(content))
    return None


def last_turn(transcript_path):
    """最後のユーザー入力の本文と、それより後のアシスタントの text ブロックを返す。"""
    texts = []
    judged = False
    try:
        for line in reversed_lines(transcript_path):
            # 前回の Stop より前の返答はそのときに判定済み。差し戻しは isMeta の user 行で区切りにならないので、
            # これを見ないと書き直し済みの英語で毎回止める
            if b'"subtype":"stop_hook_summary"' in line:
                judged = True
                continue
            # ツールの結果は数 MB になることがあり、全部を解析すると長いターンで hook の時間切れになる
            if b'"type":"tool_result"' in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("isSidechain"):
                continue
            prompt = prompt_text(row)
            if prompt is not None:
                return prompt, texts
            content = (row.get("message") or {}).get("content")
            if not judged and row.get("type") == "assistant" and isinstance(content, list):
                texts[:0] = text_blocks(content)
    except OSError:
        pass
    return "", texts


def main():
    if os.environ.get("SKIP_JAPANESE_REPLY") == "1":
        return
    # claude -p や SDK から呼ばれたときは出力を別のプログラムが読むので、言語を縛らない
    if os.environ.get("CLAUDE_CODE_ENTRYPOINT", "").startswith("sdk"):
        return
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict):
        return
    # 書き直させた後にまた止めると、判定を外したときに抜けられなくなる
    if data.get("stop_hook_active"):
        return

    prompt, texts = last_turn(data.get("transcript_path") or "")
    if ASKED_ENGLISH.search(prompt):
        return
    # 最後の返答がまだトランスクリプトに書き出されていないことがあるので、入力の分も見る
    last = data.get("last_assistant_message")
    if last and last not in texts:
        texts.append(last)
    if any(is_english(t) for t in texts):
        json.dump({"decision": "block", "reason": REASON}, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
