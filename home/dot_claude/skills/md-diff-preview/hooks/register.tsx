import type { BuiltinToolResults, EngineInterface, Register, RenderInput } from 'claude-code'

import { applyEdit, buildHunkDiff, buildRichDiff, isMarkdownPath, unapplyPatch, type Hunk, type RichDiff } from './markdown'

type WriteResult = BuiltinToolResults['Write']
type EditResult = BuiltinToolResults['Edit']
type Shown = { filePath: string; isNew: boolean; diff: RichDiff }

const asMarkdownWrite = (tool: string, output: unknown): WriteResult | EditResult | null => {
  if (tool !== 'Write' && tool !== 'Edit') return null
  const o = output as WriteResult | EditResult | undefined
  if (!o || typeof o !== 'object' || !isMarkdownPath(o.filePath ?? '') || o.staged) return null
  return o
}

// 編集前と編集後の全文が分かれば文書全体で比べ、見出しを文脈に添えられる
const versionsOf = async (
  $: EngineInterface,
  tool: string,
  o: WriteResult | EditResult,
  hunks: Hunk[],
): Promise<{ before: string; after: string } | null> => {
  if (tool === 'Write') {
    const w = o as WriteResult
    if (w.type === 'create') return { before: '', after: w.content }
    const before = w.originalFile ?? unapplyPatch(w.content, hunks)
    return before === null ? null : { before, after: w.content }
  }
  const ed = o as EditResult
  if (ed.originalFile) {
    return { before: ed.originalFile, after: applyEdit(ed.originalFile, ed.oldString, ed.newString, ed.replaceAll) }
  }
  // 会話欄に渡る Edit の結果は originalFile が空なので、今のファイルを編集後とみなす。後の編集を
  // 含んでいると unapplyPatch の照合で外れ、hunk だけで比べる経路に落ちる
  const current = await $.fs.read(ed.filePath).catch(() => null)
  const before = typeof current === 'string' ? unapplyPatch(current, hunks) : null
  return before === null || typeof current !== 'string' ? null : { before, after: current }
}

// 変わったブロックが 1 つも見つからないときは null を返し、元の diff に任せる。空白だけの変更
// （行末の空白、空行の増減）はブロックの比較では消え、プレビューにすると変更が見えなくなるため
const shownOf = async ($: EngineInterface, tool: string, o: WriteResult | EditResult): Promise<Shown | null> => {
  const hunks = o.structuredPatch ?? []
  const versions = await versionsOf($, tool, o, hunks)
  const diff = (versions && buildRichDiff(versions.before, versions.after)) ?? buildHunkDiff(hunks)
  if (diff.added + diff.removed === 0) return null
  return { filePath: o.filePath, isNew: tool === 'Write' && (o as WriteResult).type === 'create', diff }
}

// 呼び出しの行は、画面の表示範囲が変わるたびに描き直される。そのたびに差分を作り直すと、
// 計算が重いうえ、Edit の行は後の編集を含んだファイルを読み直し、過去の行の表示が変わってしまう。
// 最初に描いたときに 1 回だけ作り、以降はそれを見せる
const MEMO_MAX = 200
const memo = new Map<string, Promise<Shown | null>>()
const memoized = ($: EngineInterface, id: string, tool: string, o: WriteResult | EditResult): Promise<Shown | null> => {
  const hit = memo.get(id)
  if (hit) return hit
  const shown = shownOf($, tool, o).catch(() => null)
  memo.set(id, shown)
  if (memo.size > MEMO_MAX) memo.delete(memo.keys().next().value!)
  return shown
}

const BAR = { add: 'diffAddedWord', del: 'diffRemovedWord' } as const

const draw = ($: EngineInterface, e: RenderInput, tool: string, { filePath, isNew, diff }: Shown) => {
  const { Box, Markdown, Text } = $.ui.resolve(e)
  return (
    <Box flexDirection="column">
      <Text bold>{`${tool === 'Write' ? 'Write' : 'Update'}(${filePath})`}</Text>
      <Text dimColor>
        Markdown preview · {isNew ? 'new file' : `+${diff.added} -${diff.removed} blocks`}
        {diff.isTruncated ? ' · truncated' : ''}
      </Text>
      {isNew ? (
        // 新規作成は全ブロックが追加なので、帯を付けずに文書として見せる
        <Box borderStyle="round" borderColor="gray" paddingX={1} flexDirection="column">
          <Markdown text={diff.items.map(it => ('text' in it ? it.text : '')).join('\n\n') || '(empty)'} />
        </Box>
      ) : (
        <Box flexDirection="column" gap={1} paddingTop={1}>
          {diff.items.map((it, i) =>
            it.kind === 'gap' ? (
              <Box key={`gap-${i}`}>
                <Text dimColor>
                  {'  '}⋯{it.count === null ? '' : ` ${it.count} unchanged ${it.count === 1 ? 'block' : 'blocks'}`}
                </Text>
              </Box>
            ) : (
              <Box key={`block-${i}`} flexDirection="row">
                {it.kind === 'same' ? <Box width={1} /> : <Box width={1} backgroundColor={BAR[it.kind]} />}
                <Box flexDirection="column" flexGrow={1} paddingLeft={1}>
                  <Markdown text={it.text} dimColor={it.kind === 'del'} />
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
    const o = isRunning || isErrored || isInterrupted ? null : asMarkdownWrite(tool, output)
    const shown = o && (await memoized($, e.props.tool_use_id, tool, o))
    if (!shown) return next(e)
    return draw($, e, tool, shown)
  })

  // Write の結果（「Wrote N lines」と中身）は、呼び出しの行とは別に結果だけの行（ToolResult）にも
  // 描かれる。呼び出しの行にプレビューを出したときだけ、ここを空にして二重に見せない。呼び出しの行が
  // 描かれない・プレビューをやめたとき（中断、空白だけの変更）は、結果の行が唯一の表示になる
  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const pending = memo.get(e.props.tool_use_id)
    if (!pending || !(await pending)) return next(e)
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
}
