import { closeFence, type Hunk } from './preview'

export type Block = { kind: 'same' | 'add' | 'del'; text: string }
export type Item = Block | { kind: 'gap'; count: number }

export type RichDiff = {
  items: Item[]
  added: number
  removed: number
  isTruncated: boolean
}

export const MAX_LINES = 80
// ブロック数の積がこれを超える文書は、差分の表が大きくなりすぎるので扱わない
const MAX_CELLS = 250_000

const FENCE = /^\s{0,3}(```|~~~)/
const HEADING = /^\s{0,3}#{1,6}\s/

const normalize = (text: string): string => text.replace(/\r\n?/g, '\n')

// 編集後の全文に diff を逆に当てて、編集前の全文を作る。後ろの hunk から戻すと、
// 前の hunk の行番号がずれない
export const unapplyPatch = (after: string, hunks: Hunk[]): string => {
  const lines = normalize(after).split('\n')
  for (const h of [...hunks].sort((a, b) => b.newStart - a.newStart)) {
    const old = h.lines.filter(l => !l.startsWith('+')).map(l => l.slice(1))
    // 新規の行を足しただけの hunk は newStart が挿入位置の 1 つ前を指す
    const start = h.newLines === 0 ? h.newStart : h.newStart - 1
    lines.splice(start, h.newLines, ...old)
  }
  return lines.join('\n')
}

// 空行・見出し・コードブロックの境目で分ける。リストや表は空行までを 1 ブロックにする
export const splitBlocks = (text: string): string[] => {
  const blocks: string[] = []
  let cur: string[] = []
  let fence: string | null = null
  const flush = () => {
    if (cur.length > 0) blocks.push(cur.join('\n'))
    cur = []
  }
  for (const line of normalize(text).split('\n')) {
    const mark = FENCE.exec(line)?.[1]
    if (fence) {
      cur.push(line)
      if (mark === fence) {
        fence = null
        flush()
      }
      continue
    }
    if (mark) {
      flush()
      fence = mark
      cur.push(line)
    } else if (line.trim() === '') {
      flush()
    } else if (HEADING.test(line)) {
      flush()
      cur.push(line)
      flush()
    } else {
      cur.push(line)
    }
  }
  flush()
  return blocks
}

const key = (block: string): string =>
  block
    .split('\n')
    .map(l => l.trimEnd())
    .join('\n')

// 最長共通部分列で、ブロックの並びの差分を取る
export const diffBlocks = (before: string[], after: string[]): Block[] | null => {
  const n = before.length
  const m = after.length
  if (n * m > MAX_CELLS) return null
  const a = before.map(key)
  const b = after.map(key)
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
    }
  }
  const out: Block[] = []
  let i = 0
  let j = 0
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      out.push({ kind: 'same', text: after[j]! })
      i++
      j++
    } else if (i < n && (j >= m || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) {
      // 同点なら削除を先に出す。置き換えが「旧 → 新」の順に読める
      out.push({ kind: 'del', text: before[i]! })
      i++
    } else {
      out.push({ kind: 'add', text: after[j]! })
      j++
    }
  }
  return out
}

// 変わったブロックに、属する見出しと前後 1 ブロックを文脈として添え、残りは畳む
export const buildRichDiff = (before: string, after: string): RichDiff | null => {
  const blocks = diffBlocks(splitBlocks(before), splitBlocks(after))
  if (!blocks) return null

  const keep = new Set<number>()
  blocks.forEach((b, i) => {
    if (b.kind === 'same') return
    keep.add(i)
    if (i > 0) keep.add(i - 1)
    if (i + 1 < blocks.length) keep.add(i + 1)
    for (let k = i - 1; k >= 0; k--) {
      const prev = blocks[k]!
      if (prev.kind !== 'del' && HEADING.test(prev.text)) {
        keep.add(k)
        break
      }
    }
  })

  const items: Item[] = []
  let budget = MAX_LINES
  let isTruncated = false
  let skipped = 0
  blocks.forEach((b, i) => {
    if (!keep.has(i)) {
      skipped++
      return
    }
    if (budget <= 0) {
      isTruncated = true
      return
    }
    if (skipped > 0) items.push({ kind: 'gap', count: skipped })
    skipped = 0
    const lines = b.text.split('\n')
    if (lines.length > budget) {
      isTruncated = true
      items.push({ ...b, text: closeFence(lines.slice(0, budget)).join('\n') })
    } else {
      items.push(b)
    }
    budget -= lines.length
  })
  if (skipped > 0 && !isTruncated) items.push({ kind: 'gap', count: skipped })

  return {
    items,
    added: blocks.filter(b => b.kind === 'add').length,
    removed: blocks.filter(b => b.kind === 'del').length,
    isTruncated,
  }
}
