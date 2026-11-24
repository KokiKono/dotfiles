import type { BuiltinToolResults, EngineInterface, Register, RenderInput } from 'claude-code'

import { applyEdit, buildPreview, isMarkdownPath, newSideOf, type Hunk, type Preview } from './preview'
import { buildRichDiff, unapplyPatch, type RichDiff } from './richdiff'

type WriteResult = BuiltinToolResults['Write']
type EditResult = BuiltinToolResults['Edit']
type Body = { type: 'rich'; diff: RichDiff } | { type: 'plain'; preview: Preview }
type Shown = { filePath: string; counts: string; isTruncated: boolean; body: Body }

// 編集前と編集後の全文。会話欄に渡る Edit の結果は originalFile が空のことがあるので、
// そのときは今のファイルを編集後とみなし、diff を逆に当てて編集前を作る
const versionsOf = async (
  $: EngineInterface,
  tool: string,
  o: WriteResult | EditResult,
  hunks: Hunk[],
): Promise<{ before: string; after: string } | null> => {
  if (tool === 'Write') {
    const w = o as WriteResult
    return { before: w.originalFile ?? unapplyPatch(w.content, hunks), after: w.content }
  }
  const ed = o as EditResult
  if (ed.originalFile && ed.originalFile.includes(ed.oldString)) {
    return {
      before: ed.originalFile,
      after: applyEdit(ed.originalFile, ed.oldString, ed.newString, ed.replaceAll),
    }
  }
  const current = await $.fs.read(ed.filePath).catch(() => null)
  if (typeof current !== 'string' || !current.includes(ed.newString)) return null
  const before = unapplyPatch(current, hunks)
  // 今のファイルが後の編集を含んでいると、逆に当てた結果が編集前と合わない
  return before.includes(ed.oldString) ? { before, after: current } : null
}

const shownOf = async ($: EngineInterface, tool: string, output: unknown): Promise<Shown | null> => {
  if (tool !== 'Write' && tool !== 'Edit') return null
  const o = output as WriteResult | EditResult | undefined
  if (!o || typeof o !== 'object' || !isMarkdownPath(o.filePath ?? '') || o.staged) return null
  const hunks = o.structuredPatch ?? []
  const plain = (preview: Preview, counts = `+${preview.added} -${preview.removed} lines`): Shown => ({
    filePath: o.filePath,
    counts,
    isTruncated: preview.isTruncated,
    body: { type: 'plain', preview },
  })

  if (tool === 'Write' && (o as WriteResult).type === 'create') {
    return plain(buildPreview((o as WriteResult).content, []), 'new file')
  }
  const versions = await versionsOf($, tool, o, hunks)
  if (!versions) {
    return hunks.length > 0 ? plain({ ...buildPreview('', hunks), text: newSideOf(hunks) }) : null
  }
  const diff = buildRichDiff(versions.before, versions.after)
  if (!diff) return plain(buildPreview(versions.after, hunks))
  return {
    filePath: o.filePath,
    counts: `+${diff.added} -${diff.removed} blocks`,
    isTruncated: diff.isTruncated,
    body: { type: 'rich', diff },
  }
}

const BAR = { add: 'diffAddedWord', del: 'diffRemovedWord' } as const

const draw = ($: EngineInterface, e: RenderInput, heading: string, shown: Shown) => {
  const { Box, Markdown, Text } = $.ui.resolve(e)
  const { body } = shown
  return (
    <Box flexDirection="column">
      <Text bold>{heading}</Text>
      <Text dimColor>
        Markdown preview · {shown.counts}
        {shown.isTruncated ? ' · truncated' : ''}
      </Text>
      {body.type === 'plain' ? (
        <Box borderStyle="round" borderColor="gray" paddingX={1} flexDirection="column">
          <Markdown text={body.preview.text || '(empty)'} />
        </Box>
      ) : (
        // GitHub の rich diff に倣い、整形した本文の左に削除は赤、追加は緑の帯を付ける
        <Box flexDirection="column" gap={1} paddingTop={1}>
          {body.diff.items.map(item =>
            item.kind === 'gap' ? (
              <Text dimColor>
                {'  '}⋯ {item.count} unchanged {item.count === 1 ? 'block' : 'blocks'}
              </Text>
            ) : (
              <Box flexDirection="row">
                {item.kind === 'same' ? <Box width={1} /> : <Box width={1} backgroundColor={BAR[item.kind]} />}
                <Box flexDirection="column" flexGrow={1} paddingLeft={1}>
                  <Markdown text={item.text} dimColor={item.kind === 'del'} />
                </Box>
              </Box>
            ),
          )}
        </Box>
      )}
    </Box>
  )
}

export const register: Register = on => {
  // プレビューは呼び出しの行（ToolUse）に描く。端末は Edit の diff をこの行に結果ごと描くため
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const { tool, output, isRunning, isErrored, isInterrupted } = e.props
    // isExpanded は見ない。端末は単独の Edit の行を ctrl+o を押していなくても true で渡すので、
    // ctrl+o のときだけ diff に戻す、という使い方ができない
    const shown = isRunning || isErrored || isInterrupted ? null : await shownOf($, tool, output)
    if (!shown) return next(e)
    return draw($, e, `${tool === 'Write' ? 'Write' : 'Update'}(${shown.filePath})`, shown)
  })

  // Write の結果（「Wrote N lines」と中身）は、呼び出しの行とは別に結果だけの行（ToolResult）へ描かれる。
  // プレビューを出した呼び出しの結果は、ここで空にして二重に見せない
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const { tool, output, isErrored } = e.props
    const shown = isErrored ? null : await shownOf($, tool, output)
    if (!shown) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
}
