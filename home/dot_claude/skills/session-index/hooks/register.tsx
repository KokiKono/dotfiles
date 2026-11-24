import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { buildIndex, refsFor } from './extract'
import type { Ref } from './extract'

const index = atom({ plugin: 'session-index', key: 'index' } as const, null)

const MAX_CHIPS = 6
const CARD_MAX_COLUMNS = 80

const rebuild = async ($: EngineInterface): Promise<void> => {
  const messages = await $.session.messages({ as: 'api' })
  await update($, index, previous => buildIndex(messages, previous))
}

// hover の scope は全サイトで共有されるので、同じラベルを参照するほかの返答のカードまで
// 一緒に開かないよう、返答（requestId）ごとに別の名前にする。scope は 64 文字まで
const scopeOf = (requestId: string, i: number): string => `si:${requestId.slice(-48)}:${i}`

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await rebuild($)

    return result
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    await rebuild($)

    return result
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const current = await read($, index)
    const refs: Ref[] = current === null ? [] : refsFor(e.props.text, current).slice(0, MAX_CHIPS)

    if (refs.length === 0) {
      return next(e)
    }

    const { Box, Text, Markdown } = $.ui.resolve(e)
    const width = Math.min(CARD_MAX_COLUMNS, Math.max(20, (e.viewport?.columns ?? CARD_MAX_COLUMNS) - 6))

    // カードは位置を固定せず、チップの行の下に差し込む。absolute で本文の上に重ねると、
    // 端末には背景を塗りつぶす色が無く、下の本文がカードの隙間から透けて読めなくなる
    return (
      <Box flexDirection="column">
        {await next(e)}
        <Box paddingLeft={2} gap={1} flexWrap="wrap">
          {refs.map((ref, i) => (
            <Text dimColor hover={{ scope: scopeOf(e.requestId, i), dimColor: false, bold: true }}>
              ↳ {ref.label}
            </Text>
          ))}
        </Box>
        {refs.map((ref, i) => (
          <Box
            key={`card-${i}`}
            display="none"
            hover={{ scope: scopeOf(e.requestId, i), display: 'flex' }}
            flexDirection="column"
            marginLeft={2}
            width={width}
            borderStyle="round"
            borderColor="suggestion"
            paddingX={1}
          >
            <Text color="suggestion" bold>
              {ref.def.seq === 0 ? `${ref.label}（compact 前の定義）` : ref.label}
            </Text>
            <Markdown text={ref.def.excerpt} />
          </Box>
        ))}
      </Box>
    )
  })
}
