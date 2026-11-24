import { expect, test } from 'claude-code/testing'

import { buildIndex, definitionsIn, labelsIn, refsFor } from './extract'

const msg = (role: 'user' | 'assistant', ...texts: string[]) => ({
  role,
  content: texts.map(text => ({ type: 'text', text })),
})

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
  expect(labelsIn('案Aと案 Bと案Ｃ、A案、選択肢2、Option C')).toEqual(['案A', '案B', '案C', 'A案', '選択肢2', 'OptionC'])
  // 「案内」「方針」のような普通の語は拾わない
  expect(labelsIn('案内を見て方針を決める')).toEqual([])
})

test('a list item that opens with a label is a definition and keeps its nested lines', async () => {
  const defs = definitionsIn(PROPOSAL, 3)

  expect(defs.map(d => d.label)).toEqual(['案A', '案B'])
  expect(defs[0]?.excerpt).toBe('- **案A**: hook で毎回検査する\n  - 速いが誤検知がある')
  expect(defs[1]?.excerpt).toBe('- **案B**: CI でだけ検査する')
})

test('a heading definition runs until the next heading of the same level', async () => {
  const text = '## 案A\n\n本文1\n\n### 補足\n\n本文2\n\n## 案B\n\n本文3'
  const defs = definitionsIn(text, 1)

  expect(defs[0]?.excerpt).toBe('## 案A\n\n本文1\n\n### 補足\n\n本文2')
  expect(defs[1]?.excerpt).toBe('## 案B\n\n本文3')
})

test('a table row whose first cell is a label is a definition', async () => {
  const defs = definitionsIn('| 案 | 内容 |\n| --- | --- |\n| 案A | 速い |\n| 案B | 安全 |', 1)

  expect(defs.map(d => d.excerpt)).toEqual(['| 案A | 速い |', '| 案B | 安全 |'])
})

test('a mention in running text is not a definition', async () => {
  expect(definitionsIn('案A にする場合は hook を足します', 1)).toEqual([])
})

test('a later reply that mentions a label gets the definition from an earlier message', async () => {
  const later = '案A にする場合は、hook の誤検知を先に潰します。'
  const index = buildIndex([msg('user', '方針を出して'), msg('assistant', PROPOSAL), msg('user', 'ok'), msg('assistant', later)], null)
  const refs = refsFor(later, index)

  expect(refs.map(r => r.label)).toEqual(['案A'])
  expect(refs[0]?.def.excerpt).toContain('hook で毎回検査する')
})

test('the reply that defines the labels gets no chips for them', async () => {
  const index = buildIndex([msg('assistant', PROPOSAL)], null)

  expect(refsFor(PROPOSAL, index)).toEqual([])
})

test('when a label is defined twice, a reply sees the definition before it', async () => {
  const second = '- 案A: 全部書き直す'
  const between = '案A で進めます'
  const after = '案A の続きです'
  const index = buildIndex([msg('assistant', PROPOSAL), msg('assistant', between), msg('assistant', second), msg('assistant', after)], null)

  expect(refsFor(between, index)[0]?.def.line).toBe('- **案A**: hook で毎回検査する')
  expect(refsFor(after, index)[0]?.def.line).toBe('- 案A: 全部書き直す')
})

test('a reply still being written, not yet indexed, takes the latest definition', async () => {
  const index = buildIndex([msg('assistant', PROPOSAL)], null)

  expect(refsFor('案B だと遅くなります', index)[0]?.def.line).toBe('- **案B**: CI でだけ検査する')
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
  const index = buildIndex([ask], null)

  expect(index.defs['案A']?.[0]?.excerpt).toBe('どれにしますか？\n案A（推奨）: 速い')
})

test('a definition that compaction dropped from the history is kept from the previous index', async () => {
  const before = buildIndex([msg('assistant', PROPOSAL)], null)
  const after = buildIndex([msg('user', '<summary>要約</summary>'), msg('assistant', '案A で進めます')], before)

  expect(after.defs['案A']?.[0]?.seq).toBe(0)
  expect(refsFor('案A で進めます', after)[0]?.def.line).toBe('- **案A**: hook で毎回検査する')
})

test('injected reminders are not indexed', async () => {
  const index = buildIndex([msg('user', '<system-reminder>\n- 案A: 古い\n</system-reminder>')], null)

  expect(index.defs).toEqual({})
})
