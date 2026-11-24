import type { Def, Index } from '../types'

// 「案A」「A案」「選択肢2」「方針B」のような、後から名前だけで呼ばれる見出しの語
const PREFIXED = '(?:案|選択肢|オプション|パターン|プラン|方針|アプローチ|Option|Plan|Approach)'
const LABEL_SRC = `(?:${PREFIXED}\\s?[A-Z0-9]{1,2}(?![A-Za-z0-9])|(?<![A-Za-z0-9])[A-Z]案)`
const LABEL = new RegExp(LABEL_SRC, 'g')

// 定義とみなすのは、行頭のラベルが見出し・太字・表の 1 列目のどれかになっているか、
// 直後に「:」「（」が続くものだけ。「案A にする場合は」のような行頭の言及は参照として扱う
const ITEM = '[-*+]\\s+|\\d+[.)]\\s+'
const DEFINING_FORMS: { kind: Kind; re: RegExp }[] = [
  { kind: 'heading', re: new RegExp(`^(\\s*)(#{1,6})\\s+(?:\\*\\*|__)?(${LABEL_SRC})`) },
  { kind: 'table', re: new RegExp(`^(\\s*)\\|\\s*(?:\\*\\*|__)?(${LABEL_SRC})(?:\\*\\*|__)?\\s*\\|`) },
  { kind: 'item', re: new RegExp(`^(\\s*)(?:${ITEM})?(?:\\*\\*|__)(${LABEL_SRC})`) },
  { kind: 'item', re: new RegExp(`^(\\s*)(?:${ITEM})?(${LABEL_SRC})\\s*(?:[:：（(｜—–]|$)`) },
]

type Kind = 'heading' | 'table' | 'item'
type Opening = { kind: Kind; indent: number; headingLevel: number; label: string }

const openingOf = (line: string): Opening | undefined => {
  for (const { kind, re } of DEFINING_FORMS) {
    const m = re.exec(line)

    if (m) {
      const indent = (m[1] ?? '').length
      const label = kind === 'heading' ? m[3] : m[2]
      const headingLevel = kind === 'heading' ? (m[2] ?? '').length : 0

      return label === undefined ? undefined : { kind, indent, headingLevel, label: label.replace(/\s/g, '') }
    }
  }

  return undefined
}

const MAX_EXCERPT_LINES = 12
const MAX_EXCERPT_CHARS = 600
const KEY_CHARS = 120

// 全角英数字と全角空白を半角にそろえる。「案Ａ」と「案A」を同じ語として扱うため
export const normalize = (text: string): string =>
  text
    .replace(/[Ａ-Ｚａ-ｚ０-９]/g, c => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/　/g, ' ')

const canonical = (label: string): string => label.replace(/\s/g, '')

export const labelsIn = (text: string): string[] => {
  const seen = new Set<string>()

  for (const m of normalize(text).matchAll(LABEL)) {
    seen.add(canonical(m[0]))
  }

  return [...seen]
}

// 返答のブロックを、描画時に受け取る本文と突き合わせるための鍵
export const blockKey = (text: string): string => normalize(text).replace(/\s+/g, ' ').trim().slice(0, KEY_CHARS)

const isBoundary = (line: string, indent: number, headingLevel: number): boolean => {
  const heading = /^(#{1,6})\s/.exec(line)

  if (heading) {
    return headingLevel === 0 || (heading[1] ?? '').length <= headingLevel
  }

  if (headingLevel > 0) {
    return false
  }

  const lead = /^(\s*)([-*+]\s|\d+[.)]\s|\|)/.exec(line)

  return lead !== null && (lead[1] ?? '').length <= indent
}

const cap = (lines: string[]): string => {
  const kept = lines.slice(0, MAX_EXCERPT_LINES).join('\n').trim()
  const cut = kept.length > MAX_EXCERPT_CHARS ? `${kept.slice(0, MAX_EXCERPT_CHARS)}…` : kept

  return lines.length > MAX_EXCERPT_LINES && cut === kept ? `${cut}\n…` : cut
}

export const definitionsIn = (text: string, seq: number): Def[] => {
  const lines = normalize(text).split('\n')
  const defs: Def[] = []

  lines.forEach((line, i) => {
    const opening = openingOf(line)

    if (opening === undefined) {
      return
    }

    const body = [line]

    // 見出しは次の同じか上の階層の見出しまで、箇条書きや太字の段落は空行か次の項目まで
    if (opening.kind !== 'table') {
      for (const next of lines.slice(i + 1)) {
        if (isBoundary(next, opening.indent, opening.headingLevel) || (opening.kind === 'item' && next.trim() === '')) {
          break
        }

        body.push(next)
      }
    }

    defs.push({ label: opening.label, line: line.trim(), excerpt: cap(body), seq })
  })

  return defs
}

type Block = { type: string; [field: string]: unknown }
type Message = { role: 'user' | 'assistant'; content: Block[] }

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
      const label = typeof o.label === 'string' ? labelsIn(o.label)[0] : undefined

      if (label === undefined) {
        return []
      }

      const description = typeof o.description === 'string' ? o.description : ''
      const line = `${String(o.label)}${description ? `: ${description}` : ''}`

      return [{ label, line, excerpt: `${typeof q.question === 'string' ? `${q.question}\n` : ''}${line}`, seq }]
    }),
  )
}

// エンジンが差し込むリマインダーやタスクの通知は、人も Claude も書いていないので索引に入れない
const isInjected = (text: string): boolean => /^\s*</.test(text)

export const buildIndex = (messages: Message[], previous: Index | null): Index => {
  const defs: Record<string, Def[]> = {}
  const seqOf: Record<string, number> = {}
  let seq = 0

  for (const message of messages) {
    for (const block of message.content) {
      seq += 1

      if (block.type === 'text' && typeof block.text === 'string' && !isInjected(block.text)) {
        for (const def of definitionsIn(block.text, seq)) {
          ;(defs[def.label] ??= []).push(def)
        }

        if (message.role === 'assistant' && labelsIn(block.text).length > 0) {
          seqOf[blockKey(block.text)] = seq
        }
      }

      if (block.type === 'tool_use' && block.name === 'AskUserQuestion') {
        for (const def of optionDefs(block.input, seq)) {
          ;(defs[def.label] ??= []).push(def)
        }
      }
    }
  }

  // compact で古い発言が要約に置き換わると、そこにあった定義は履歴から消える。
  // 前回の索引にしか無いラベルは、どの発言よりも前（seq 0）の定義として残す
  for (const [label, olds] of Object.entries(previous?.defs ?? {})) {
    const last = olds[olds.length - 1]

    if (!(label in defs) && last !== undefined) {
      defs[label] = [{ ...last, seq: 0 }]
    }
  }

  return { defs, seqOf }
}

export type Ref = { label: string; def: Def }

// 描画するブロックが参照しているラベルのうち、ほかの発言で定義したものを返す。
// 同じラベルが何度も定義されていれば、このブロックより前の最後の定義を採る
// 索引に無いブロック（書いている途中の返答）は、索引の最後の定義を採る
export const refsFor = (text: string, index: Index): Ref[] => {
  const own = index.seqOf[blockKey(text)]
  const definedHere = new Set(definitionsIn(text, 0).map(d => d.label))

  return labelsIn(text).flatMap(label => {
    if (definedHere.has(label)) {
      return []
    }

    const candidates = (index.defs[label] ?? []).filter(d => own === undefined || d.seq < own)
    const def = candidates[candidates.length - 1]

    return def === undefined ? [] : [{ label, def }]
  })
}
