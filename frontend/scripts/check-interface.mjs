// Verify the actual Controls call mapper against the current Demo ABI; sends no transactions.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { encodeFunctionData, decodeFunctionData, parseUnits } from 'viem'

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(resolve(here, '../src/pages/Controls.tsx'), 'utf8')
const ast = ts.createSourceFile('Controls.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
const mapper = ast.statements.find((s) => ts.isFunctionDeclaration(s) && s.name?.text === 'toCall')
const expiry = ast.statements.find((s) => ts.isVariableStatement(s) && s.declarationList.declarations.some((d) => d.name.getText(ast) === 'endOfDayCST'))
assert.ok(mapper && expiry, 'Controls call mapper not found')
const js = ts.transpileModule(`${expiry.getText(ast)}\n${mapper.getText(ast)}`, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext },
}).outputText
const toCall = new Function('parseUnits', `${js}\nreturn toCall`)(parseUnits)
const { abi } = JSON.parse(readFileSync(resolve(here, '../../contracts/out/CountersignDemo.sol/CountersignDemo.json'), 'utf8'))
const address = '0x0000000000000000000000000000000000000008'
const id = '0x' + '01'.repeat(32)
const amount = 1250000000000000000n
const queues = [
  ['AddVendor', { vendor_id: 8, payout: address }, 'queueAddVendor', [8n, address]],
  ['SetPayout', { vendor_id: 8, new_payout: address }, 'queuePayoutChange', [8n, address]],
  ['AddPO', { po_id: 102, vendor_id: 8, cap: '1.25', expiry: '2099-12-31', period_days: 30 }, 'queueAddPO', [102n, 8n, amount, BigInt(Date.parse('2099-12-31T15:59:59Z') / 1000), 30]],
  ['AddAgent', { agent: address }, 'queueAgentAuthorization', [address]],
  ['RaiseDailyCap', { new_cap: '1.25' }, 'queueLimitIncrease', [1, amount]],
  ['RaisePOBudget', { po_id: 102, new_cap: '1.25' }, 'queuePOBudgetIncrease', [102n, amount]],
  ['Unpause', {}, 'queueResume', []],
  ['Withdraw', { amount: '1.25' }, 'queueWithdraw', [amount]],
]
const cases = [
  [{ type: 'pause' }, 'pause', []],
  [{ type: 'deactivateVendor', vendorId: 8 }, 'deactivateVendor', [8n]],
  [{ type: 'closePO', poId: 102 }, 'closePO', [102n]],
  [{ type: 'revokeAgent', agent: address }, 'revokeAgent', [address]],
  [{ type: 'lowerDailyCap', cap: '1.25' }, 'decreaseLimit', [1, amount]],
  [{ type: 'execute', id }, 'execute', [id]],
  [{ type: 'cancel', id }, 'cancel', [id]],
  ...queues.map(([kind, decoded, name, args]) => [{ type: 'queue', kind, decoded }, name, args]),
]
for (const [action, name, args] of cases) {
  const call = toCall(action, 18)
  assert.equal(call.functionName, name)
  assert.deepEqual(call.args, args)
  const encoded = encodeFunctionData({ abi, ...call })
  assert.equal(decodeFunctionData({ abi, data: encoded }).functionName, name)
}
console.log(`当前页面 ${cases.length} 种调用与 Demo ABI 的名称、参数和编码匹配；未发送交易。`)
