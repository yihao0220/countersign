// Exercise the actual page sender and waiting row without another test framework.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import ts from 'typescript'

const source = readFileSync(fileURLToPath(new URL('../src/pages/Controls.tsx', import.meta.url)), 'utf8')
const ast = ts.createSourceFile('Controls.tsx', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
const live = ast.statements.find((s) => ts.isFunctionDeclaration(s) && s.name?.text === 'LiveControls')
const act = live.body.statements.flatMap((s) => ts.isVariableStatement(s) ? [...s.declarationList.declarations] : [])
  .find((d) => d.name.getText(ast) === 'act').initializer.arguments[0]
const row = ast.statements.find((s) => ts.isFunctionDeclaration(s) && s.name?.text === 'PendingRow')
const compile = (code) => ts.transpileModule(code, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ESNext, jsx: ts.JsxEmit.React },
}).outputText
const owner = '0x0000000000000000000000000000000000000001'
let account = { isConnected: true, chainId: 31337, address: owner }
let sent = 0
const env = {
  config: { network: 'local', chain_id: 31337, owner_address: owner },
  wagmiConfig: {}, getAccount: () => account, tr: (_en, zh) => zh,
  localOwnerAction: async () => { sent++; return 'test-receipt' },
  api: { ownerTx: async () => {} },
}
const send = new Function(...Object.keys(env), compile(`const act = ${act.getText(ast)};`) + '\nreturn act;')(...Object.values(env))
const change = { type: 'queue', kind: 'SetPayout', decoded: { vendor_id: 7, new_payout: owner } }
// The callback is retained throughout: it must read current connection at send time.
account = { ...account, isConnected: false }
await assert.rejects(send(change), /请先连接/)
account = { ...account, isConnected: true, chainId: 1 }
await assert.rejects(send(change), /请先连接/)
account = { ...account, chainId: 31337, address: '0x0000000000000000000000000000000000000002' }
await assert.rejects(send(change), /只有 Owner/)
assert.equal(sent, 0, 'Rejected actions must not call the local backend')
await send({ type: 'execute', id: 'approved-change' })
assert.equal(sent, 1, 'Execution remains public to connected accounts')
account = { ...account, address: owner }
await send(change)
assert.equal(sent, 2, 'Reconnecting the Owner permits normal queuing')

const rowEnv = {
  React, useState: React.useState, useCallback: React.useCallback,
  useLang: () => ({ tr: (_en, zh) => zh }), changeAddress: () => null,
  CHANGE_LABEL: { AddVendor: { zh: '新增供应商' } }, describeChange: () => '供应商 9',
  shortAddr: (id) => id, Countdown: () => '0:00',
}
const PendingRow = new Function(...Object.keys(rowEnv), compile(row.getText(ast)) + '\nreturn PendingRow;')(...Object.values(rowEnv))
const props = {
  reg: { vendors: [] }, symbol: 'LOCAL', lang: 'zh', canSend: true, isOwner: true,
  busy: null, run: () => {},
}
const render = (ready, eta) => renderToStaticMarkup(React.createElement(PendingRow, {
  ...props, c: { id: 'approved-change', kind: 'AddVendor', decoded: {}, ready, eta },
}))
const waiting = render(false, '2000-01-01T00:00:00Z')
assert.match(waiting, /disabled=""[^>]*>执行/, 'An advanced client clock must not enable a chain-pending action')
const ready = render(true, '2099-01-01T00:00:00Z')
assert.match(ready, /可执行/)
assert.doesNotMatch(ready, /disabled=""[^>]*>执行/, 'Chain readiness must override a lagging client clock')
console.log('控制台回归检查通过：断开/错链/非 Owner 不发送；公共执行保留；到期状态以后台为准。未发送实际交易。')
