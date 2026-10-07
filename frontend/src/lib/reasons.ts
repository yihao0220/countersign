import { blockReasons } from '../abi/BlockReasons'

// CountersignDemo BlockReason: generated from the catalog shared with the backend.
export const REASONS = blockReasons.map((r) => r.name)
export type ReasonName = (typeof blockReasons)[number]['name']
export const REASON_LABELS: Record<string, { en: string; zh: string }> = Object.fromEntries(
  blockReasons.map((r) => [r.name, { en: r.en, zh: r.zh }]),
)

export function reasonLabel(reason: string | null | undefined, lang: 'zh' | 'en'): string {
  if (!reason) return ''
  const l = REASON_LABELS[reason]
  return l ? l[lang] : reason
}

// Off-chain guard flag codes (SPEC §3.5)
export const FLAG_LABELS: Record<string, { en: string; zh: string }> = {
  HIDDEN_TEXT: { en: 'Hidden text in the file', zh: '文件里有隐藏文字' },
  PAYOUT_CHANGED: { en: 'Invoice asks to pay a different address', zh: '发票要求付到另一个地址' },
  LOOKALIKE_VENDOR: { en: 'Vendor name imitates a real vendor', zh: '供应商名称冒充真实供应商' },
  UNKNOWN_PO: { en: 'Purchase order not found', zh: '找不到采购单' },
  PO_VENDOR_MISMATCH: { en: 'PO belongs to another vendor', zh: '采购单不属于该供应商' },
  OVER_BUDGET: { en: 'Amount exceeds the remaining budget', zh: '金额超出剩余预算' },
  DUPLICATE_INVOICE: { en: 'This invoice was already paid', zh: '这张发票已经付过款' },
  INSTRUCTION_TO_AGENT: { en: 'Text gives instructions to the AI', zh: '文字在给 AI 下指令' },
  PAYMENT_DETAILS_CHANGE: { en: 'Tries to change payment details', zh: '试图修改收款信息' },
  VENDOR_IMPERSONATION: { en: 'Impersonates a vendor', zh: '冒充供应商' },
  URGENCY_PRESSURE: { en: 'Pressure to pay urgently', zh: '催促立即付款' },
  AMOUNT_ANOMALY: { en: 'Unusual amount', zh: '金额异常' },
}
export function flagLabel(code: string, lang: 'zh' | 'en'): string {
  const l = FLAG_LABELS[code]
  return l ? l[lang] : code
}
