import type { EngineInterface, RenderInput } from 'claude-code'
import { expect, test } from 'claude-code/testing'

const ORIGINAL = '# T\n\n## A\n\nold\n\n## B\n\nb\n'

const ROW = {
  plugin: 'md-diff-preview',
  component: 'ToolUse',
  requestId: 'toolu_1',
  props: {
    tool_use_id: 'toolu_1',
    tool: 'Edit',
    input: { file_path: '/x/doc.md', old_string: 'old', new_string: '**new**' },
    isRunning: false,
    isErrored: false,
    isInterrupted: false,
    isExpanded: true,
    output: {
      filePath: '/x/doc.md',
      oldString: 'old',
      newString: '**new**',
      originalFile: ORIGINAL,
      structuredPatch: [{ oldStart: 5, oldLines: 1, newStart: 5, newLines: 1, lines: ['-old', '+**new**'] }],
      userModified: false,
      replaceAll: false,
    },
  },
} as const

const WRITE = { type: 'create', filePath: '/x/new.md', content: '# New', structuredPatch: [], originalFile: null }

const writeRow = (component: 'ToolUse' | 'ToolResult', id: string) => ({
  plugin: 'md-diff-preview',
  component,
  requestId: id,
  surface: 'terminal' as const,
  props: {
    tool_use_id: id,
    tool: 'Write',
    input: { file_path: WRITE.filePath, content: WRITE.content },
    isRunning: false,
    isErrored: false,
    isInterrupted: false,
    output: WRITE,
  },
})

// エンジンの描画の代わり。プラグインが next(e) に流したときだけ、この文言が出る
const engine = (label: string) => ($: EngineInterface, e: RenderInput) => {
  const { Text } = $.ui.resolve(e)
  return <Text>{label}</Text>
}

test('an Edit of a markdown file draws the preview', async ($, on) => {
  on('ui.render', engine('engine diff'))

  const ui = await $.ui.mount({ ...ROW, surface: 'terminal' })

  expect(await ui.find({ type: 'Text', text: /engine diff/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Markdown preview/ }))?.text).toContain('+1 -1 blocks')
  expect((await ui.find({ type: 'Text', text: /^Update/ }))?.text).toBe('Update(/x/doc.md)')
  await ui.unmount()
})

test('a whitespace-only edit is left to the engine diff', async ($, on) => {
  on('ui.render', engine('engine diff'))
  // 行末に空白 2 つ（改行の指定）を足しただけ。ブロックの比較では変化が消える
  const output = { ...ROW.props.output, oldString: 'old', newString: 'old  ', structuredPatch: [] }

  const ui = await $.ui.mount({
    ...ROW,
    requestId: 'toolu_ws',
    surface: 'terminal',
    props: { ...ROW.props, tool_use_id: 'toolu_ws', output },
  })

  expect((await ui.find({ type: 'Text', text: /engine diff/ }))?.text).toBe('engine diff')
  await ui.unmount()
})

test('the separate result row of a previewed write draws nothing', async ($, on) => {
  on('ui.render', engine('engine result'))

  const call = await $.ui.mount(writeRow('ToolUse', 'toolu_2'))
  const result = await $.ui.mount(writeRow('ToolResult', 'toolu_2'))

  expect(await result.find({ type: 'Text', text: /engine result/ })).toBeUndefined()
  await result.unmount()
  await call.unmount()
})

test('a result row whose call drew no preview keeps the engine drawing', async ($, on) => {
  on('ui.render', engine('engine result'))

  // 呼び出しの行が描かれていない（中断した、別の画面で畳まれた）ときは、結果の行が唯一の表示
  const result = await $.ui.mount(writeRow('ToolResult', 'toolu_3'))

  expect((await result.find({ type: 'Text', text: /engine result/ }))?.text).toBe('engine result')
  await result.unmount()
})
