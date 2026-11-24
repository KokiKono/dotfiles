import { expect, test } from 'claude-code/testing'

import { buildRichDiff, splitBlocks, unapplyPatch } from './richdiff'

test('splits on blank lines, headings and fences, keeping lists and tables whole', async () => {
  const text = ['# T', 'para', '', '- a', '- b', '```sh', '# x', '', 'y', '```', '| a |', '| - |'].join('\n')

  expect(splitBlocks(text)).toEqual(['# T', 'para', '- a\n- b', '```sh\n# x\n\ny\n```', '| a |\n| - |'])
})

test('undoes a patch to rebuild the text before the edit', async () => {
  const after = ['a', 'B', 'c', 'd', 'e'].join('\n')
  // 2 行目の b を B に変え、5 行目の後ろにあった f を消した
  const hunks = [
    { oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [' a', '-b', '+B', ' c'] },
    { oldStart: 5, oldLines: 2, newStart: 5, newLines: 1, lines: [' e', '-f'] },
  ]

  expect(unapplyPatch(after, hunks)).toBe(['a', 'b', 'c', 'd', 'e', 'f'].join('\n'))
})

test('marks changed blocks and keeps their heading and neighbours as context', async () => {
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
