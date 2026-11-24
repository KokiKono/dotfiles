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

test('an Edit of a markdown file draws the preview', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine diff</Text>
  })

  const ui = await $.ui.mount({ ...ROW, surface: 'terminal' })

  expect(await ui.find({ type: 'Text', text: /engine diff/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Markdown preview/ }))?.text).toContain('+1 -1 blocks')
  expect((await ui.find({ type: 'Text', text: /^Update/ }))?.text).toBe('Update(/x/doc.md)')
  await ui.unmount()
})

test('the separate result row of a previewed write draws nothing', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine result</Text>
  })

  const ui = await $.ui.mount({
    plugin: 'md-diff-preview',
    component: 'ToolResult',
    requestId: 'toolu_2',
    surface: 'terminal',
    props: {
      tool_use_id: 'toolu_2',
      tool: 'Write',
      isErrored: false,
      output: { type: 'create', filePath: '/x/new.md', content: '# New', structuredPatch: [], originalFile: null },
    },
  })

  expect(await ui.find({ type: 'Text', text: /engine result/ })).toBeUndefined()
  await ui.unmount()
})
