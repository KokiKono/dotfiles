import type { Def, Index } from '../types'

// 「案A」「A案」「選択肢2」「方針B」のような、後から名前だけで呼ばれる見出しの語
const PREFIXED = '(?:案|選択肢|オプション|パターン|プラン|方針|アプローチ|Option|Plan|Approach)'
const LABEL_SRC = `(?:${PREFIXED}\\s?[A-Z0-9]{1,2}(?![A-Za-z0-9])|(?<![A-Za-z0-9])[A-Z]案)`
const LABEL = new RegExp(LABEL_SRC, 'g')

// 定義とみなすのは、行頭のラベルが見出し・太字・表の 1 列目のどれかになっているか、直後に
// 区切りの記号（: ： ( （ ｜ — –）が続くか、ラベルだけで行が終わるものだけ。
// 「案A にする場合は」のような行頭の言及は参照として扱う
const ITEM = '(?:[-*+]\\s+|\\d+[.)]\\s+)?'
const BOLD = '(?:\\*\\*|__)'
const L = `(?<label>${LABEL_SRC})`
const DEFINING_FORMS: { kind: Kind; re: RegExp }[] = [
  { kind: 'heading', re: new RegExp(`^\\s*(?<hashes>#{1,6})\\s+${BOLD}?${L}`) },
  { kind: 'table', re: new RegExp(`^\\s*\\|\\s*${BOLD}?${L}${BOLD}?\\s*\\|`) },
  { kind: 'item', re: new RegExp(`^(?<indent>\\s*)${ITEM}${BOLD}${L}`) },
  { kind: 'item', re: new RegExp(`^(?<indent>\\s*)${ITEM}${L}\\s*(?:[:：（(｜—–]|$)`) },
]

type Kind = 'heading' | 'table' | 'item'
type Opening =
  | { kind: 'heading'; level: number; label: string }
  | { kind: 'table'; label: string }
  | { kind: 'item'; indent: number; label: string }

const MAX_EXCERPT_LINES = 12
const MAX_EXCERPT_CHARS = 600
const KEY_CHARS = 120

// 全角英数字と全角空白を半角にそろえる。「案Ａ」と「案A」を同じ語として扱うため
const normalize = (text: string): string =>
  text
    .replace(/[Ａ-Ｚａ-ｚ０-９]/g, c => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/　/g, ' ')

const canonical = (label: string): string => label.replace(/\s/g, '')

// labelsOf・openingOf・keyOf・definitionsOf は normalize 済みの本文を受け取る。
// 生の本文を渡すと、全角で書いたラベル（案Ａ）を取りこぼす
const labelsOf = (text: string): string[] => [...new Set(Array.from(text.matchAll(LABEL), m => canonical(m[0])))]

const openingOf = (line: string): Opening | undefined => {
  for (const { kind, re } of DEFINING_FORMS) {
    const g = re.exec(line)?.groups

    if (g?.label !== undefined) {
      const label = canonical(g.label)

      return kind === 'heading'
        ? { kind, level: (g.hashes ?? '').length, label }
        : kind === 'table'
          ? { kind, label }
          : { kind, indent: (g.indent ?? '').length, label }
    }
  }

  return undefined
}

// 返答のブロックを、描画時に受け取る本文と突き合わせるための鍵。
// 履歴（$.session.messages）のブロックには id が無く、描画側の id はメッセージ単位なので
// ブロックを見分けられない。描画される本文は隠す部分（<context> など）が除かれ、書いている
// 途中なら末尾が欠けるので、全文ではなく空白を畳んだ先頭だけで突き合わせる
const keyOf = (text: string): string => text.replace(/\s+/g, ' ').trim().slice(0, KEY_CHARS)

const ends = (line: string, opening: Opening): boolean => {
  const heading = /^(#{1,6})\s/.exec(line)

  if (opening.kind === 'heading') {
    return heading !== null && (heading[1] ?? '').length <= opening.level
  }

  const item = /^(\s*)(?:[-*+]\s|\d+[.)]\s|\|)/.exec(line)

  return line.trim() === '' || heading !== null || (item !== null && (item[1] ?? '').length <= (opening.kind === 'item' ? opening.indent : 0))
}

const cap = (lines: string[]): string => {
  const kept = lines.slice(0, MAX_EXCERPT_LINES).join('\n').trim()
  const isCut = lines.length > MAX_EXCERPT_LINES || kept.length > MAX_EXCERPT_CHARS

  return `${kept.slice(0, MAX_EXCERPT_CHARS)}${isCut ? '…' : ''}`
}

const definitionsOf = (text: string, seq: number): Def[] => {
  const lines = text.split('\n')
  const defs: Def[] = []

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] ?? ''
    // 行ごとに定義の形の正規表現をすべて当てる前に、ラベルの無い行を落とす。
    // LABEL は g 付きで test が位置を覚えるので、次の行のために戻す
    const opening = LABEL.test(line) ? openingOf(line) : undefined
    LABEL.lastIndex = 0

    if (opening === undefined) {
      continue
    }

    let end = i + 1

    if (opening.kind !== 'table') {
      while (end < lines.length && !ends(lines[end] ?? '', opening)) {
        end += 1
      }
    }

    defs.push({ label: opening.label, excerpt: cap(lines.slice(i, end)), seq })
  }

  return defs
}

type Option = { label?: unknown; description?: unknown }
type Question = { question?: unknown; options?: unknown }

// AskUserQuestion の選択肢も定義として拾う。ラベルに「案A」と書いて出すことが多いため
const optionDefs = (input: unknown, seq: number): Def[] => {
  const questions = (input as { questions?: unknown } | null)?.questions

  if (!Array.isArray(questions)) {
    return []
  }

  return (questions as Question[]).flatMap(q =>
    (Array.isArray(q.options) ? (q.options as Option[]) : []).flatMap(o => {
      const name = typeof o.label === 'string' ? normalize(o.label) : ''
      const label = labelsOf(name)[0]

      if (label === undefined) {
        return []
      }

      const line = typeof o.description === 'string' && o.description ? `${name}: ${o.description}` : name
      const excerpt = [q.question, line].filter(s => typeof s === 'string').join('\n')

      return [{ label, excerpt, seq }]
    }),
  )
}

// エンジンが差し込むリマインダーやタスクの通知は、人も Claude も書いていないので索引に入れない
const isInjected = (text: string): boolean => /^\s*</.test(text)

type Block = { type: string; [field: string]: unknown }
type Message = { role: 'user' | 'assistant'; content: Block[] }

export const buildIndex = (messages: Message[], previous: Index | null): Index => {
  const defs: Record<string, Def[]> = {}
  const seqOf: Record<string, number> = {}
  let seq = 0

  for (const message of messages) {
    for (const block of message.content) {
      seq += 1
      let found: Def[] = []

      if (block.type === 'text' && typeof block.text === 'string' && !isInjected(block.text)) {
        const text = normalize(block.text)

        if (labelsOf(text).length > 0) {
          found = definitionsOf(text, seq)

          if (message.role === 'assistant') {
            seqOf[keyOf(text)] = seq
          }
        }
      } else if (block.type === 'tool_use' && block.name === 'AskUserQuestion') {
        found = optionDefs(block.input, seq)
      }

      for (const def of found) {
        ;(defs[def.label] ??= []).push(def)
      }
    }
  }

  // compact で古い発言が要約に置き換わると、そこにあった定義は履歴から消える。
  // 前回の索引にしか無いラベルは、どの発言よりも前（seq 0）の定義として残す
  for (const [label, olds] of Object.entries(previous?.defs ?? {})) {
    const last = olds.at(-1)

    if (!(label in defs) && last !== undefined) {
      defs[label] = [{ ...last, seq: 0 }]
    }
  }

  return { defs, seqOf }
}

// 描画するブロックが参照しているラベルのうち、ほかの発言で定義したものを返す。
// 同じラベルが何度も定義されていれば、このブロックより前の最後の定義を採る。
// 索引に無いブロック（書いている途中の返答）は、索引の最後の定義を採る
export const refsFor = (rawText: string, index: Index) => {
  const text = normalize(rawText)
  const own = index.seqOf[keyOf(text)]
  const lines = text.split('\n')
  const definedHere = new Set(lines.map(line => openingOf(line)?.label))

  return labelsOf(text).flatMap(label => {
    const def = definedHere.has(label) ? undefined : index.defs[label]?.findLast(d => own === undefined || d.seq < own)

    return def === undefined ? [] : [{ label, def }]
  })
}

// 描画で索引を読む前に、ラベルを含まない返答を安く落とすための判定
export const mentionsLabel = (rawText: string): boolean => {
  const has = LABEL.test(normalize(rawText))
  // g 付きの test が覚えた位置を戻す。残すと次の呼び出しが途中から探す
  LABEL.lastIndex = 0

  return has
}

// hover の scope に使う、ブロックの本文の短い指紋
export const fingerprint = (text: string): string => {
  let h = 5381

  for (let i = 0; i < text.length; i += 1) {
    h = ((h << 5) + h + text.charCodeAt(i)) | 0
  }

  return (h >>> 0).toString(36)
}
