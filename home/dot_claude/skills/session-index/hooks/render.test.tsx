import type { EngineInterface, RenderInput } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { buildIndex } from './extract'

const PROPOSAL = '- **案A**: hook で毎回検査する\n- **案B**: CI でだけ検査する'

const reply = (text: string, id = 'msg_1') =>
  ({
    plugin: 'session-index',
    component: 'AssistantMessage',
    requestId: id,
    surface: 'terminal',
    viewport: { columns: 120, rows: 40, isFullscreen: true },
    props: { text, isFirstOfReply: true },
  }) as const

// エンジンの描画の代わり。プラグインが next(e) に流したときだけ、この文言が出る
const engine = ($: EngineInterface, e: RenderInput) => {
  const { Text } = $.ui.resolve(e)
  return <Text>engine reply</Text>
}

// 前の版が残した索引。エンジンの state として渡す
const INDEX = buildIndex([{ role: 'assistant', content: [{ type: 'text', text: PROPOSAL }] }], null)
const stored = () => ({ value: { value: INDEX, version: 1 } })

test('a reply that mentions an earlier label keeps its text and gets a chip and a hidden card', async ($, on) => {
  on('ui.render', engine)
  on('state.get', stored)

  const ui = await $.ui.mount(reply('案A にする場合は hook を足します'))

  expect((await ui.find({ type: 'Text', text: /engine reply/ }))?.text).toBe('engine reply')
  expect((await ui.find({ type: 'Text', text: /↳/ }))?.text).toBe('↳ 案A')

  const card = await ui.find({ type: 'Box', key: 'card-0' })
  // hover で開く側の指定はテストの要素に載らないので、閉じた状態で描くことだけを見る
  expect(card?.props.display).toBe('none')
  expect((await ui.find({ type: 'Markdown' }))?.text).toBe('- **案A**: hook で毎回検査する')
  await ui.unmount()
})

test('a reply with no indexed label is left to the engine', async ($, on) => {
  on('ui.render', engine)
  on('state.get', stored)

  const ui = await $.ui.mount(reply('案C は未定義です', 'msg_2'))

  expect((await ui.find({ type: 'Text', text: /engine reply/ }))?.text).toBe('engine reply')
  expect(await ui.find({ type: 'Text', text: /↳/ })).toBeUndefined()
  await ui.unmount()
})

test('before any index is built, replies draw as the engine draws them', async ($, on) => {
  on('ui.render', engine)

  const ui = await $.ui.mount(reply('案A で進めます', 'msg_3'))

  expect(await ui.find({ type: 'Text', text: /↳/ })).toBeUndefined()
  await ui.unmount()
})
