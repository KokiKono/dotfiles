import { expect, test } from 'claude-code/testing'

import { buildIndex, carryOver, refsFor } from './extract'

const msg = (role: 'user' | 'assistant', ...texts: string[]) => ({
  role,
  content: texts.map(text => ({ type: 'text', text })),
})

const defsIn = (text: string) =>
  Object.values(buildIndex([msg('assistant', text)], {}).defs).flat()

const PROPOSAL = [
  '方針は 2 つあります。',
  '',
  '- **案A**: hook で毎回検査する',
  '  - 速いが誤検知がある',
  '- **案B**: CI でだけ検査する',
  '',
  'どちらにしますか？',
].join('\n')

test('labels are found in many spellings and full-width forms are folded', async () => {
  const text = ['- 案A: a', '- 案 B: b', '- 案Ｃ: c', '- A案: d', '- 選択肢2: e', '- Option C: f'].join('\n')

  expect(defsIn(text).map(d => d.label)).toEqual(['案A', '案B', '案C', 'A案', '選択肢2', 'OptionC'])
  // 「案内」「方針」のような普通の語は拾わない
  expect(defsIn('- 案内: 見る\n- 方針: 決める')).toEqual([])
})

test('a list item that opens with a label is a definition and keeps its nested lines', async () => {
  const defs = defsIn(PROPOSAL)

  expect(defs.map(d => d.label)).toEqual(['案A', '案B'])
  expect(defs[0]?.excerpt).toBe('- **案A**: hook で毎回検査する\n  - 速いが誤検知がある')
  expect(defs[1]?.excerpt).toBe('- **案B**: CI でだけ検査する')
})

test('a heading definition runs until the next heading of the same level', async () => {
  const text = '## 案A\n\n本文1\n\n### 補足\n\n本文2\n\n## 案B\n\n本文3'
  const defs = defsIn(text)

  expect(defs[0]?.excerpt).toBe('## 案A\n\n本文1\n\n### 補足\n\n本文2')
  expect(defs[1]?.excerpt).toBe('## 案B\n\n本文3')
})

test('a table row whose first cell is a label is a definition', async () => {
  const defs = defsIn('| 案 | 内容 |\n| --- | --- |\n| 案A | 速い |\n| 案B | 安全 |')

  expect(defs.map(d => d.excerpt)).toEqual(['| 案A | 速い |', '| 案B | 安全 |'])
})

test('a mention in running text is not a definition', async () => {
  expect(defsIn('案A にする場合は hook を足します')).toEqual([])
})

test('a later reply that mentions a label gets the definition from an earlier message', async () => {
  const later = '案A にする場合は、hook の誤検知を先に潰します。'
  const index = buildIndex([msg('user', '方針を出して'), msg('assistant', PROPOSAL), msg('user', 'ok'), msg('assistant', later)], {})
  const refs = refsFor(later, index)

  expect(refs.map(r => r.label)).toEqual(['案A'])
  expect(refs[0]?.def.excerpt).toContain('hook で毎回検査する')
})

test('the reply that defines the labels gets no chips for them', async () => {
  const index = buildIndex([msg('assistant', PROPOSAL)], {})

  expect(refsFor(PROPOSAL, index)).toEqual([])
})

test('when a label is defined twice, a reply sees the definition before it', async () => {
  const second = '- 案A: 全部書き直す\n- 案B: 捨てる'
  const between = '案A で進めます'
  const after = '案A の続きです'
  const index = buildIndex([msg('assistant', PROPOSAL), msg('assistant', between), msg('assistant', second), msg('assistant', after)], {})

  expect(refsFor(between, index)[0]?.def.excerpt).toContain('- **案A**: hook で毎回検査する')
  expect(refsFor(after, index)[0]?.def.excerpt).toBe('- 案A: 全部書き直す')
})

test('a reply still being written, not yet indexed, takes the latest definition', async () => {
  const index = buildIndex([msg('assistant', PROPOSAL)], {})

  expect(refsFor('案B だと遅くなります', index)[0]?.def.excerpt).toBe('- **案B**: CI でだけ検査する')
})

test('AskUserQuestion options that carry a label are definitions', async () => {
  const ask = {
    role: 'assistant' as const,
    content: [
      {
        type: 'tool_use',
        name: 'AskUserQuestion',
        input: { questions: [{ question: 'どれにしますか？', options: [{ label: '案A（推奨）', description: '速い' }] }] },
      },
    ],
  }
  const index = buildIndex([ask], {})

  expect(index.defs['案A']?.[0]?.excerpt).toBe('どれにしますか？\n案A（推奨）: 速い')
})

test('a definition carried over a compaction stays, and a later redefinition does not hide it', async () => {
  const carried = carryOver(buildIndex([msg('assistant', PROPOSAL)], {}))
  // compact の要約はユーザー側の行に入る。要約の中の「- 案A: …」は定義として拾わない
  const summary = msg('user', 'This session is being continued...\n- 案A: hook\n- 案B: CI')
  const between = '案A で進めます'
  const after = buildIndex([summary, msg('assistant', between), msg('assistant', '- 案A: 別の話\n- 案B: 別の話')], carried)

  expect(after.defs['案A']?.[0]?.seq).toBe(0)
  expect(refsFor(between, after)[0]?.def.excerpt).toContain('- **案A**: hook で毎回検査する')
})

test('a definition removed from the history without a compaction (a rewind) is dropped', async () => {
  const before = buildIndex([msg('assistant', PROPOSAL)], {})
  const after = buildIndex([msg('assistant', '案A で進めます')], before.carried)

  expect(after.defs).toEqual({})
})

test('a recap that names one label does not replace the definition', async () => {
  const recap = '- **案A** を採用しました'
  const index = buildIndex([msg('assistant', PROPOSAL), msg('assistant', recap), msg('assistant', '案A の続き')], {})

  expect(index.defs['案A']).toHaveLength(1)
  expect(refsFor(recap, index)[0]?.def.excerpt).toContain('hook で毎回検査する')
})

test('a label inside a longer word or followed by a counter is not a label', async () => {
  expect(defsIn('- 改善案A: a\n- 代替案B: b\n- 提案1: c')).toEqual([])
  expect(defsIn('- パターン2つ: a\n- 案3個: b')).toEqual([])
  // 助詞の後ろは別の語の一部ではないので、参照として拾う
  expect(refsFor('方針は案A で', buildIndex([msg('assistant', PROPOSAL)], {})).map(r => r.label)).toEqual(['案A'])
})
