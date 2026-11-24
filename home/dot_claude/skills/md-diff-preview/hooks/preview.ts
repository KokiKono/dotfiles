export type Hunk = {
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
  lines: string[]
}

export type Preview = {
  text: string
  added: number
  removed: number
  isTruncated: boolean
}

export const MAX_LINES = 80

const MD_PATH = /\.(md|mdx|markdown)$/i
const FENCE = /^\s{0,3}(```|~~~)/
const HEADING = /^\s{0,3}(#{1,6})\s/

export const isMarkdownPath = (path: string): boolean => MD_PATH.test(path)

// Edit の結果は編集後の全文を持たない。今のファイルは後の編集を含みうるので、
// 編集前の全文があればそれに置換を当て直して作る
export const applyEdit = (
  original: string,
  oldString: string,
  newString: string,
  replaceAll: boolean,
): string =>
  replaceAll
    ? original.split(oldString).join(newString)
    : original.replace(oldString, () => newString)

// 全文が取れないときの代わり。diff の新しい側（変更行と前後の数行）だけをつなぐ
export const newSideOf = (hunks: Hunk[]): string =>
  hunks
    .map(h => h.lines.filter(l => !l.startsWith('-')).map(l => l.slice(1)).join('\n'))
    .join('\n\n---\n\n')

// 見出しの行番号（0 始まり）とレベル。コードフェンスの中の # は見出しではない
const headings = (lines: string[]): { line: number; level: number }[] => {
  const found: { line: number; level: number }[] = []
  let inFence = false
  lines.forEach((line, i) => {
    if (FENCE.test(line)) {
      inFence = !inFence
      return
    }
    const hashes = inFence ? undefined : HEADING.exec(line)?.[1]
    if (hashes) found.push({ line: i, level: hashes.length })
  })
  return found
}

// 変更した行を含む節（直前の見出しから、同じか上のレベルの次の見出しの手前まで）。
// 行単位で切ると表やリスト、コードフェンスが途中で切れて整形が崩れるため節で切る
const sectionOf = (
  hs: { line: number; level: number }[],
  total: number,
  from: number,
  to: number,
): [number, number] => {
  const head = [...hs].reverse().find(h => h.line <= from)
  if (!head) {
    const next = hs.find(h => h.line > to)
    return [0, next ? next.line : total]
  }
  const end = hs.find(h => h.line > Math.max(to, head.line) && h.level <= head.level)
  return [head.line, end ? end.line : total]
}

export const buildPreview = (content: string, hunks: Hunk[]): Preview => {
  const lines = content.replace(/\r\n?/g, '\n').split('\n')
  let added = 0
  let removed = 0
  for (const h of hunks) {
    for (const l of h.lines) {
      if (l.startsWith('+')) added += 1
      else if (l.startsWith('-')) removed += 1
    }
  }

  // 新規作成や diff が無いとき（大きすぎて取れなかった等）は先頭から見せる
  const ranges: [number, number][] = []
  if (hunks.length === 0) {
    ranges.push([0, lines.length])
  } else {
    const hs = headings(lines)
    for (const h of hunks) {
      const from = Math.max(0, h.newStart - 1)
      const to = Math.max(from, from + h.newLines - 1)
      ranges.push(sectionOf(hs, lines.length, from, to))
    }
  }

  ranges.sort((a, b) => a[0] - b[0])
  const merged: [number, number][] = []
  for (const r of ranges) {
    const last = merged[merged.length - 1]
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1])
    else merged.push([...r])
  }

  const chunks: string[] = []
  let budget = MAX_LINES
  let isTruncated = false
  for (const [start, end] of merged) {
    if (budget <= 0) {
      isTruncated = true
      break
    }
    const take = lines.slice(start, Math.min(end, start + budget))
    if (start + take.length < end) isTruncated = true
    budget -= take.length
    chunks.push(closeFence(take).join('\n'))
  }

  return {
    // Markdown 要素が受け付ける制御文字はタブと改行だけ
    text: chunks.join('\n\n---\n\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, ''),
    added,
    removed,
    isTruncated,
  }
}

// 上限で切ったときにフェンスが開いたままだと、以降がすべてコードとして描かれる
export const closeFence = (lines: string[]): string[] => {
  let open: string | null = null
  for (const l of lines) {
    const fence = FENCE.exec(l)?.[1]
    if (fence) open = open ? null : fence
  }
  return open ? [...lines, open] : lines
}
