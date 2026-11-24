import { expect, test } from 'claude-code/testing'

import { MAX_LINES, applyEdit, buildHunkDiff, buildRichDiff, diffBlocks, splitBlocks, unapplyPatch } from './markdown'

test('splits on blank lines, headings and fences, keeping lists and tables whole', async () => {
  const text = ['# T', 'para', '', '- a', '- b', '```sh', '# x', '', 'y', '```', '| a |', '| - |'].join('\n')

  expect(splitBlocks(text)).toEqual(['# T', 'para', '- a\n- b', '```sh\n# x\n\ny\n```', '| a |\n| - |'])
})

test('a fence closes only on the same marker', async () => {
  expect(splitBlocks(['```', '~~~', '```', 'after'].join('\n'))).toEqual(['```\n~~~\n```', 'after'])
})

test('a longer fence is not closed by a shorter one or a line with an info string', async () => {
  const text = ['````md', '```js', 'x', '```', '````', 'after'].join('\n')

  expect(splitBlocks(text)).toEqual(['````md\n```js\nx\n```\n````', 'after'])
})

test('diffs the middle after trimming equal ends, deletions before additions', async () => {
  const blocks = diffBlocks(['a', 'b', 'old', 'c'], ['a', 'b', 'new', 'c'])

  expect(blocks).toEqual([
    { kind: 'same', text: 'a' },
    { kind: 'same', text: 'b' },
    { kind: 'del', text: 'old' },
    { kind: 'add', text: 'new' },
    { kind: 'same', text: 'c' },
  ])
})

test('keeps the heading and neighbours of a change as context and folds the rest', async () => {
  const before = ['# T', 'intro', '## A', 'a1', 'a2', 'a3 old', 'a4', 'a5'].join('\n\n')
  const after = ['# T', 'intro', '## A', 'a1', 'a2', 'a3 new', 'a4', 'a5'].join('\n\n')
  const diff = buildRichDiff(before, after)!

  // 見出し ## A、前後 1 ブロック（a2 と a4）、削除と追加。間の a1 と末尾の a5 は畳む
  expect(diff.items).toEqual([
    { kind: 'gap', count: 2 },
    { kind: 'same', text: '## A' },
    { kind: 'gap', count: 1 },
    { kind: 'same', text: 'a2' },
    { kind: 'del', text: 'a3 old' },
    { kind: 'add', text: 'a3 new' },
    { kind: 'same', text: 'a4' },
    { kind: 'gap', count: 1 },
  ])
  expect(diff.added).toBe(1)
  expect(diff.removed).toBe(1)
})

test('a new file is every block added', async () => {
  const diff = buildRichDiff('', '# New\n\nbody')!

  expect(diff.items).toEqual([
    { kind: 'add', text: '# New' },
    { kind: 'add', text: 'body' },
  ])
})

test('without the whole files, compares each hunk on its own', async () => {
  // 2 つの hunk。1 つ目は段落の書き換え、2 つ目は節の削除
  const hunks = [
    { oldStart: 3, oldLines: 3, newStart: 3, newLines: 3, lines: [' ## A', ' ', '-old', '+new'] },
    { oldStart: 20, oldLines: 3, newStart: 20, newLines: 0, lines: ['-## Z', '-', '-z'] },
  ]
  const diff = buildHunkDiff(hunks)

  expect(diff.items).toEqual([
    { kind: 'same', text: '## A' },
    { kind: 'del', text: 'old' },
    { kind: 'add', text: 'new' },
    { kind: 'gap', count: null },
    { kind: 'del', text: '## Z' },
    { kind: 'del', text: 'z' },
  ])
  expect(diff.removed).toBe(3)
})

test('cuts at the line limit and closes a fence left open', async () => {
  const code = ['```', ...Array.from({ length: MAX_LINES + 10 }, (_, i) => `l${i}`), '```'].join('\n')
  const diff = buildRichDiff('', code)!
  const text = (diff.items[0] as { text: string }).text

  expect(diff.isTruncated).toBe(true)
  expect(text.split('\n').length).toBe(MAX_LINES + 1)
  expect(text.endsWith('\n```')).toBe(true)
})

test('rebuilds the edited file from the original', async () => {
  expect(applyEdit('a b a', 'a', 'x', false)).toBe('x b a')
  expect(applyEdit('a b a', 'a', 'x', true)).toBe('x b x')
  // 置換後の文字列に $& などがあっても特殊扱いしない
  expect(applyEdit('a', 'a', '$&$&', false)).toBe('$&$&')
})

// 2 行目の b を B に変え、5 行目の後ろにあった f を消した
const HUNKS = [
  { oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [' a', '-b', '+B', ' c'] },
  { oldStart: 5, oldLines: 2, newStart: 5, newLines: 1, lines: [' e', '-f'] },
]

test('undoes a patch to rebuild the text before the edit', async () => {
  expect(unapplyPatch(['a', 'B', 'c', 'd', 'e'].join('\n'), HUNKS)).toBe(['a', 'b', 'c', 'd', 'e', 'f'].join('\n'))
})

test('refuses to undo a patch onto a file that changed after the edit', async () => {
  // 後の編集で 3 行目の c が C になっている。hunk の文脈行と合わないので戻さない
  expect(unapplyPatch(['a', 'B', 'C', 'd', 'e'].join('\n'), HUNKS)).toBeNull()
})
