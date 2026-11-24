export type Hunk = {
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
  lines: string[]
}

export type Block = { kind: 'same' | 'add' | 'del'; text: string }
// count が null の gap は hunk の境目。間に何ブロックあるかは diff から分からない
export type Item = Block | { kind: 'gap'; count: number | null }

export type RichDiff = {
  items: Item[]
  added: number
  removed: number
  isTruncated: boolean
}

export const MAX_LINES = 80
// 最長共通部分列の計算に使う升目（旧のブロック数 × 新のブロック数）の上限。1 升 4 バイトで約 1MB。
// 超えたら diffBlocks は null を返し、呼び出し側は hunk ごとに比べる経路に落ちる
const MAX_CELLS = 250_000

const MD_PATH = /\.(md|mdx|markdown)$/i
// CommonMark のフェンス。開きは 3 つ以上の ` か ~、閉じは同じ文字で開き以上の長さの並びだけの行。
// 4 連の ` で囲んだ中の ``` や、```python のような情報文字列付きの行では閉じない
const FENCE_OPEN = /^\s{0,3}(`{3,}|~{3,})/
const FENCE_CLOSE = /^\s{0,3}(`{3,}|~{3,})\s*$/
const HEADING = /^\s{0,3}#{1,6}\s/

export const isMarkdownPath = (path: string): boolean => MD_PATH.test(path)

// Edit の結果は編集後の全文を持たないので、編集前の全文に置換を当て直して作る
export const applyEdit = (
  original: string,
  oldString: string,
  newString: string,
  replaceAll: boolean,
): string =>
  replaceAll
    ? original.split(oldString).join(newString)
    : original.replace(oldString, () => newString)

// 「\ No newline at end of file」の行はどちらの側の行でもない
const sideOf = (h: Hunk, drop: '+' | '-'): string[] =>
  h.lines.filter(l => !l.startsWith(drop) && !l.startsWith('\\')).map(l => l.slice(1))

// 編集後の全文に diff を逆に当てて、編集前の全文を作る。各 hunk の位置の行が新側と 1 行残らず
// 一致しないときは null。今のファイルが後の編集を含んでいると、そこで外れる
export const unapplyPatch = (after: string, hunks: Hunk[]): string | null => {
  const lines = after.replace(/\r\n?/g, '\n').split('\n')
  // 後ろの hunk から戻すと、前の hunk の行番号がずれない
  for (const h of [...hunks].sort((a, b) => b.newStart - a.newStart)) {
    // structuredPatch（jsdiff）の newStart は新側が 0 行でも 1 始まりの位置。unified 形式に
    // 書き出すときだけ 1 を引くので、ここでは常に 1 を引けばよい
    const start = h.newStart - 1
    const expected = sideOf(h, '-')
    if (expected.some((l, k) => lines[start + k] !== l)) return null
    lines.splice(start, h.newLines, ...sideOf(h, '+'))
  }
  return lines.join('\n')
}

const fenceOf = (line: string): string | undefined => FENCE_OPEN.exec(line)?.[1]
const closes = (line: string, open: string): boolean => {
  const mark = FENCE_CLOSE.exec(line)?.[1]
  return !!mark && mark[0] === open[0] && mark.length >= open.length
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
  for (const line of text.replace(/\r\n?/g, '\n').split('\n')) {
    const mark = fenceOf(line)
    if (fence) {
      cur.push(line)
      if (closes(line, fence)) {
        fence = null
        flush()
      }
    } else if (mark) {
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

// 先頭と末尾の一致するブロックを先に削るのは、升目を変わった部分の大きさで済ませるため。削らないと、
// 1 か所だけ直した長い文書でも文書全体の升目を埋め、MAX_CELLS を超えて全文での比較を諦めてしまう
export const diffBlocks = (before: string[], after: string[]): Block[] | null => {
  const a = before.map(key)
  const b = after.map(key)
  let head = 0
  while (head < a.length && head < b.length && a[head] === b[head]) head++
  let tail = 0
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail++

  const n = a.length - head - tail
  const m = b.length - head - tail
  if (n * m > MAX_CELLS) return null
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i]![j] =
        a[head + i] === b[head + j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
    }
  }

  const out: Block[] = after.slice(0, head).map(text => ({ kind: 'same', text }))
  let i = 0
  let j = 0
  while (i < n || j < m) {
    if (i < n && j < m && a[head + i] === b[head + j]) {
      out.push({ kind: 'same', text: after[head + j]! })
      i++
      j++
    } else if (i < n && (j >= m || lcs[i + 1]![j]! >= lcs[i]![j + 1]!)) {
      // 同点なら削除を先に出す。置き換えが「旧 → 新」の順に読める
      out.push({ kind: 'del', text: before[head + i]! })
      i++
    } else {
      out.push({ kind: 'add', text: after[head + j]! })
      j++
    }
  }
  for (const text of after.slice(after.length - tail)) out.push({ kind: 'same', text })
  return out
}

// 上限で切ったときにフェンスが開いたままだと、以降がすべてコードとして描かれる
const closeFence = (lines: string[]): string[] => {
  let open: string | null = null
  for (const l of lines) {
    if (!open) open = fenceOf(l) ?? null
    else if (closes(l, open)) open = null
  }
  return open ? [...lines, open] : lines
}

// Markdown 要素が受け付ける制御文字はタブと改行だけ
const printable = (text: string): string => text.replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')

// 変わったブロックに、属する見出しと前後 1 ブロックを文脈として添え、残りは畳む
const selectContext = (items: Item[]): RichDiff => {
  const keep = new Set<number>()
  items.forEach((it, i) => {
    if (it.kind !== 'add' && it.kind !== 'del') return
    keep.add(i)
    if (i > 0) keep.add(i - 1)
    if (i + 1 < items.length) keep.add(i + 1)
    for (let k = i - 1; k >= 0; k--) {
      const prev = items[k]!
      if (prev.kind === 'gap') break
      if (prev.kind !== 'del' && HEADING.test(prev.text)) {
        keep.add(k)
        break
      }
    }
  })

  const out: Item[] = []
  let added = 0
  let removed = 0
  let budget = MAX_LINES
  let isTruncated = false
  let skipped = 0
  const flushSkipped = () => {
    if (skipped > 0) out.push({ kind: 'gap', count: skipped })
    skipped = 0
  }
  items.forEach((it, i) => {
    if (it.kind === 'add') added++
    if (it.kind === 'del') removed++
    if (isTruncated) return
    if (it.kind === 'gap') {
      flushSkipped()
      out.push(it)
    } else if (!keep.has(i)) {
      skipped++
    } else if (budget <= 0) {
      isTruncated = true
    } else {
      flushSkipped()
      const lines = it.text.split('\n')
      if (lines.length > budget) isTruncated = true
      const taken = isTruncated ? closeFence(lines.slice(0, budget)) : lines
      out.push({ ...it, text: printable(taken.join('\n')) })
      budget -= lines.length
    }
  })
  if (!isTruncated) flushSkipped()
  return { items: out, added, removed, isTruncated }
}

export const buildRichDiff = (before: string, after: string): RichDiff | null => {
  const blocks = diffBlocks(splitBlocks(before), splitBlocks(after))
  return blocks && selectContext(blocks)
}

// 全文が無いときは、hunk ごとに旧側と新側をブロックに分けて比べる。前後数行の文脈しか無いので、
// hunk の端で表やリストが途中から始まることがある
export const buildHunkDiff = (hunks: Hunk[]): RichDiff => {
  const items: Item[] = []
  hunks.forEach((h, n) => {
    if (n > 0) items.push({ kind: 'gap', count: null })
    const blocks = diffBlocks(splitBlocks(sideOf(h, '+').join('\n')), splitBlocks(sideOf(h, '-').join('\n')))
    if (blocks) items.push(...blocks)
  })
  return selectContext(items)
}
