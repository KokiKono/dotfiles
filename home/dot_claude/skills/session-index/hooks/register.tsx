import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { buildIndex, fingerprint, mentionsLabel, refsFor } from './extract'

const index = atom({ plugin: 'session-index', key: 'index' } as const, null)

const MAX_CHIPS = 6
const CARD_MAX_COLUMNS = 80

// 索引を書くと、それを読んでいる返答がすべて描き直される。中身が変わらないターンでは書かない
const rebuild = async ($: EngineInterface): Promise<void> => {
  const messages = await $.session.messages({ as: 'api' })
  const previous = await read($, index)
  const next = buildIndex(messages, previous)

  if (JSON.stringify(next) !== JSON.stringify(previous)) {
    await update($, index, () => next)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await rebuild($)

    return result
  })

  // 索引はメインの会話から作るので、subagent のターンの終わりでは作り直さない
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)

    if (e.agentId === undefined) {
      await rebuild($)
    }

    return result
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    // 索引を読むと、その描画は索引が変わるたびに描き直される。ラベルの無い返答では読まない
    const current = mentionsLabel(e.props.text) ? await read($, index) : null
    const refs = current === null ? [] : refsFor(e.props.text, current).slice(0, MAX_CHIPS)

    if (refs.length === 0) {
      return next(e)
    }

    const { Box, Text, Markdown } = $.ui.resolve(e)
    const width = Math.min(CARD_MAX_COLUMNS, Math.max(20, (e.viewport?.columns ?? CARD_MAX_COLUMNS) - 6))
    // hover の scope は全サイトで共有されるので、ほかの返答やブロックのカードまで一緒に開かないよう、
    // ブロックごとに別の名前にする。scope は 64 文字まで
    const scope = (i: number): string => `si:${e.requestId.slice(-36)}:${fingerprint(e.props.text)}:${i}`

    // カードは位置を固定せず、チップの行の下に差し込む。absolute で本文の上に重ねると、
    // 端末には背景を塗りつぶす色が無く、下の本文がカードの隙間から透けて読めなくなる
    return (
      <Box flexDirection="column">
        {await next(e)}
        <Box paddingLeft={2} gap={1} flexWrap="wrap">
          {refs.map((ref, i) => (
            <Text dimColor hover={{ scope: scope(i), dimColor: false, bold: true }}>
              ↳ {ref.label}
            </Text>
          ))}
        </Box>
        {refs.map((ref, i) => (
          <Box
            key={`card-${i}`}
            display="none"
            hover={{ scope: scope(i), display: 'flex' }}
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
