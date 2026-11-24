// 「案A」のようなラベルを定義した箇所。seq は会話の中のブロックの通し番号で、
// どの定義がどの発言より前かを決めるのに使う（0 は compact で履歴から消えた定義）
export type Def = { label: string; excerpt: string; seq: number }

export type Index = {
  defs: Record<string, Def[]>
  // ラベルを含む返答のブロックの通し番号。鍵は本文の先頭（extract.ts の keyOf）
  seqOf: Record<string, number>
}

declare module 'claude-code' {
  interface PluginState {
    'session-index': { index: Index | null }
  }
}
