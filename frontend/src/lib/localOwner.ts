import type { AppConfig } from '../api/types'

/** Local HTTP adapter only. The server validates and sends an allowlisted Demo call. */
export async function localOwnerAction(config: AppConfig, action: { type: string; kind?: string; [key: string]: unknown }) {
  if (config.network !== 'local' || config.chain_id !== 31337 || window.location.hostname !== '127.0.0.1') {
    throw new Error('本地接口只允许本机 Anvil 31337')
  }
  const supported = ['pause', 'deactivateVendor', 'closePO', 'revokeAgent', 'lowerDailyCap', 'lowerTotalBudget', 'lowerPOBudget', 'execute', 'cancel', 'queue']
  const queues = ['SetPayout', 'AddAgent', 'RaiseDailyCap', 'RaiseTotalBudget', 'RaisePOBudget', 'Unpause', 'AddVendor', 'AddPO', 'Withdraw']
  if (!supported.includes(action.type) || (action.type === 'queue' && !queues.includes(action.kind ?? ''))) {
    throw new Error('当前本地接口不支持此操作。')
  }
  const response = await fetch('/api/local/owner', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(action),
  })
  const body = await response.json()
  if (response.status === 401) window.dispatchEvent(new Event('countersign-session-expired'))
  if (!response.ok) throw new Error(body.detail ?? '本地操作未完成')
  return body.hash as string
}
