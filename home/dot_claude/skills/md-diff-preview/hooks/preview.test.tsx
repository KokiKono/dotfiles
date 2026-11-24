import { expect, test } from 'claude-code/testing'

import { applyEdit, buildPreview, MAX_LINES } from './preview'

const DOC = [
  '# Title', // 1
  'intro', // 2
  '## A', // 3
  'a1', // 4
  '```sh', // 5
  '# not a heading', // 6
  '```', // 7
  'a2', // 8
  '### A-1', // 9
  'a3', // 10
  '## B', // 11
  'b1', // 12
].join('\n')

const hunk = (newStart: number, newLines: number, lines: string[]) => ({
  oldStart: newStart,
  oldLines: newLines,
  newStart,
  newLines,
  lines,
})

test('shows the whole section holding the change, ignoring # inside fences', async () => {
  // 8 行目（## A の本文）だけを変えた: ## A の見出しから ## B の手前までを見せる
  const p = buildPreview(DOC, [hunk(8, 1, ['-old', '+a2'])])

  expect(p.text).toBe(['## A', 'a1', '```sh', '# not a heading', '```', 'a2', '### A-1', 'a3'].join('\n'))
  expect(p.added).toBe(1)
  expect(p.removed).toBe(1)
  expect(p.isTruncated).toBe(false)
})

test('a change under the top heading shows the sections below it too', async () => {
  // 2 行目は # Title の節。下位の見出しはこの節に含まれるので文書の末尾まで続き、
  // 12 行目の変更（## B）もその中に収まる
  const p = buildPreview(DOC, [hunk(2, 1, ['+intro']), hunk(12, 1, ['+b1'])])

  expect(p.text).toBe(DOC)
})

test('separates changed sections that are apart with a rule', async () => {
  const doc = ['## A', 'a', '## B', 'b', '## C', 'c'].join('\n')
  const p = buildPreview(doc, [hunk(2, 1, ['+a']), hunk(6, 1, ['+c'])])

  expect(p.text).toBe('## A\na\n\n---\n\n## C\nc')
})

test('falls back to the top of the file without a diff', async () => {
  const p = buildPreview('# New\nbody', [])

  expect(p.text).toBe('# New\nbody')
})

test('closes a fence cut by the line limit', async () => {
  const body = ['# T', '```', ...Array.from({ length: MAX_LINES + 10 }, (_, i) => `l${i}`), '```'].join('\n')
  const p = buildPreview(body, [])

  expect(p.isTruncated).toBe(true)
  expect(p.text.endsWith('\n```')).toBe(true)
})

test('rebuilds the edited file from the original', async () => {
  expect(applyEdit('a b a', 'a', 'x', false)).toBe('x b a')
  expect(applyEdit('a b a', 'a', 'x', true)).toBe('x b x')
  // 置換後の文字列に $& などがあっても特殊扱いしない
  expect(applyEdit('a', 'a', '$&$&', false)).toBe('$&$&')
})
