"""Local v1 interface: real HTTP, receipts and budget queries on isolated Anvil."""
import json
import re
from pathlib import Path

import pytest
from web3 import Web3
from app.chain.local import REASON_CATALOG, reason_fields
from test_local_integration import node, client, owner, invoice, queue_vendor, queue_po

ROOT = Path(__file__).resolve().parents[2]


def po(c, pid):
    return next(p for p in c.get('/api/registry').json()['pos'] if p['po_id'] == pid)


def pending(c, pid):
    return next(p for p in c.get('/api/registry').json()['pending_changes']
                if p['kind'] == 'RaisePOBudget' and p['decoded']['po_id'] == pid)


def jump(chain, timestamp):
    assert 'error' not in chain.w3.provider.make_request('evm_setNextBlockTimestamp', [timestamp])
    chain.w3.provider.make_request('evm_mine', [])


def test_catalog_and_generated_interfaces_match_solidity():
    source = (ROOT / 'contracts/src/CountersignDemo.sol').read_text()
    enum = re.search(r'enum BlockReason\s*\{([^}]+)\}', source).group(1)
    names = [n.strip() for n in enum.split(',')]
    assert names == [r['name'] for r in REASON_CATALOG]
    assert [r['code'] for r in REASON_CATALOG] == list(range(14))
    abi = json.loads((ROOT / 'contracts/out/CountersignDemo.sol/CountersignDemo.json').read_text())['abi']
    assert json.loads((ROOT / 'contracts/interface/CountersignDemo.abi.json').read_text()) == abi
    generated = (ROOT / 'frontend/src/abi/Countersign.ts').read_text()
    assert json.loads(generated.split(' = ', 1)[1].removesuffix(' as const\n')) == abi
    reasons = (ROOT / 'frontend/src/abi/BlockReasons.ts').read_text()
    assert json.loads(reasons.split(' = ', 1)[1].removesuffix(' as const\n')) == REASON_CATALOG


@pytest.mark.parametrize('code', range(14))
def test_real_receipt_reason_codes_and_ledger(client, code):
    c, chain, _ = client
    f = chain.contract.functions
    proposal = {'vendor_id': 7, 'pay_to': f.payout().call(), 'po_id': 101,
                'amount': '1', 'invoice_hash': Web3.to_hex(Web3.keccak(text='interface-code'))}
    if code == 1: proposal['vendor_id'] = 999
    elif code == 2: proposal['pay_to'] = chain.manifest['wrong_payout']
    elif code == 3: proposal['po_id'] = 999
    elif code == 4: proposal['amount'] = '0'
    elif code == 5: proposal['amount'] = '501'
    elif code == 6: chain.payment(proposal, 'naive', lambda _: None)
    elif code == 7: chain.w3.provider.make_request('anvil_setBalance', [chain.contract.address, '0x0'])
    elif code == 8: owner(c, {'type': 'pause'})
    elif code == 9: jump(chain, f.poExpiry().call())
    elif code == 10: proposal['amount'] = '201'
    elif code == 11: owner(c, {'type': 'deactivateVendor', 'vendorId': 7})
    elif code == 12:
        queue_vendor(c, chain); queue_po(c, chain)
        proposal['po_id'] = 102
    elif code == 13: owner(c, {'type': 'closePO', 'poId': 101})
    before = (f.totalPaid().call(), f.spentToday().call(), chain.w3.eth.get_balance(chain.contract.address))
    result = chain.payment(proposal, 'naive', lambda _: None)
    assert result['event'] == ('Paid' if code == 0 else 'Blocked')
    assert result['reason_code'] == code
    assert result['reason'] == (REASON_CATALOG[code]['name'] if code else None)
    row = c.get('/api/ledger').json()[0]
    assert row['reason_code'] == code and row['reason'] == result['reason']
    assert row['reason_label_zh'] == result['reason_label_zh']
    assert row['po_id'] == proposal['po_id'] and row['raw_name'] == result['event']
    if code:
        assert before == (f.totalPaid().call(), f.spentToday().call(), chain.w3.eth.get_balance(chain.contract.address))


@pytest.mark.parametrize('code', [-1, 14, 255])
def test_unknown_reason_fails_explicitly(code):
    with pytest.raises(ValueError, match='接口不匹配'): reason_fields(code)


def test_unknown_receipt_code_fails_payment_and_http_ledger(client, monkeypatch):
    c, chain, app = client
    original = chain.decode
    def unknown(logs):
        return [(name, args | {'reason': 255} if name == 'Blocked' else args, log)
                for name, args, log in original(logs)]
    monkeypatch.setattr(chain, 'decode', unknown)
    monkeypatch.setattr(app.state.local_chain, 'decode', unknown)
    proposal = {'vendor_id': 7, 'pay_to': chain.manifest['wrong_payout'], 'po_id': 101,
                'amount': '1', 'invoice_hash': Web3.to_hex(Web3.keccak(text='unknown-code'))}
    with pytest.raises(ValueError, match='接口不匹配'):
        chain.payment(proposal, 'naive', lambda _: None)
    response = c.get('/api/ledger?kind=blocked')
    assert response.status_code == 409 and '接口不匹配' in response.json()['detail']


def test_http_budget_round_trip(client):
    c, chain, _ = client
    queue_vendor(c, chain); queue_po(c, chain)
    assert invoice(c, 8, 102, 'BUDGET-PAID', '30')['tx']['reason_code'] == 0
    owner(c, {'type': 'queue', 'kind': 'RaisePOBudget', 'decoded': {'po_id': 102, 'new_cap': '120'}})
    p = pending(c, 102)
    assert p['decoded'] == {'po_id': 102, 'new_cap': '120'} and not p['ready']
    assert po(c, 102)['pending_budget_change_id'] == p['id']
    queued = next(e for e in c.get('/api/ledger?kind=changes').json() if e['change_id'] == p['id'])
    assert queued['name'] == 'ChangeQueued' and queued['po_id'] == 102 and queued['reason_code'] is None
    eta = chain.contract.functions.poBudgetChanges(p['id']).call()[-2]
    owner(c, {'type': 'execute', 'id': p['id']}, 409)
    jump(chain, eta)
    tx = owner(c, {'type': 'execute', 'id': p['id']})
    data = po(c, 102)
    assert data['cap'] == '120' and data['remaining'] == '90'
    assert data['spent_current_period'] == data['total_paid'] == '30'
    assert data['pending_budget_change_id'] is None
    assert chain.w3.eth.get_balance(chain.contract.address) == 470 * 10**18
    assert invoice(c, 8, 102, 'BUDGET-PAID', '30')['tx']['reason_code'] == 6
    events = [e for e in c.get('/api/ledger?kind=changes').json() if e['tx_hash'] == tx['hash']]
    assert {e['name'] for e in events} == {'POBudgetChanged', 'ChangeExecuted'}
    owner(c, {'type': 'lowerPOBudget', 'poId': 102, 'cap': '60'})
    assert po(c, 102)['remaining'] == '30' and po(c, 102)['total_paid'] == '30'
    print('PO-102: paid 30; queued cap 120; early execution rejected; executed after delay; remaining 90; history retained')


@pytest.mark.parametrize('stop', ['cancel', 'lower', 'close'])
def test_po_raise_cancel_lower_close_invalidates_pending(client, stop):
    c, chain, _ = client
    queue_vendor(c, chain); queue_po(c, chain)
    owner(c, {'type': 'queue', 'kind': 'RaisePOBudget', 'decoded': {'po_id': 102, 'new_cap': '120'}})
    p = pending(c, 102)
    if stop == 'cancel': owner(c, {'type': 'cancel', 'id': p['id']})
    elif stop == 'lower': owner(c, {'type': 'lowerPOBudget', 'poId': 102, 'cap': '60'})
    else: owner(c, {'type': 'closePO', 'poId': 102})
    assert not c.get('/api/registry').json()['pending_changes']
    assert po(c, 102)['pending_budget_change_id'] is None
    chain.w3.provider.make_request('evm_increaseTime', [120]); chain.w3.provider.make_request('evm_mine', [])
    owner(c, {'type': 'execute', 'id': p['id']}, 409)
    if stop == 'close': assert invoice(c, 8, 102, 'CLOSED')['tx']['reason_code'] == 13


@pytest.mark.parametrize('legacy', [False, True])
def test_po101_legacy_twins_display_once_but_receipt_keeps_all(client, legacy):
    c, chain, _ = client
    body = {'type': 'queue', 'kind': 'RaiseTotalBudget' if legacy else 'RaisePOBudget',
            'decoded': {'new_cap': '600', **({} if legacy else {'po_id': 101})}}
    tx = owner(c, body)
    p = pending(c, 101)
    assert len(c.get('/api/registry').json()['pending_changes']) == 1
    rows = [e for e in c.get('/api/ledger?kind=changes').json() if e['tx_hash'] == tx['hash']]
    assert len(rows) == 1 and rows[0]['raw_name'] == 'POBudgetChangeQueued'
    raw = c.get('/api/local/tx/' + tx['hash']).json()['events']
    assert {e['name'] for e in raw} == {'LimitChangeQueued', 'POBudgetChangeQueued'}
    chain.w3.provider.make_request('evm_increaseTime', [120]); chain.w3.provider.make_request('evm_mine', [])
    tx = owner(c, {'type': 'execute', 'id': p['id']})
    rows = [e for e in c.get('/api/ledger?kind=changes').json() if e['tx_hash'] == tx['hash']]
    assert len(rows) == 2 and {e['name'] for e in rows} == {'POBudgetChanged', 'ChangeExecuted'}
    owner(c, body | {'decoded': body['decoded'] | {'new_cap': '700'}})
    p2 = pending(c, 101)
    tx = owner(c, {'type': 'cancel', 'id': p2['id']})
    rows = [e for e in c.get('/api/ledger?kind=changes').json() if e['tx_hash'] == tx['hash']]
    assert len(rows) == 1 and rows[0]['name'] == 'ChangeCancelled'
    assert p2['id'] != p['id']
    # A daily limit change has a different meaning and must remain visible.
    tx = owner(c, {'type': 'lowerDailyCap', 'cap': '150'})
    rows = [e for e in c.get('/api/ledger?kind=changes').json() if e['tx_hash'] == tx['hash']]
    assert len(rows) == 1 and rows[0]['name'] == 'LimitChanged' and rows[0]['po_id'] is None


def test_period_queries_before_after_boundary_without_payment(client, monkeypatch):
    c, chain, _ = client
    queue_vendor(c, chain); queue_po(c, chain, days=1)
    assert invoice(c, 8, 102, 'PERIOD-QUERY', '30')['outcome'] == 'paid'
    start = chain.contract.functions.purchaseOrders(102).call()[6]
    jump(chain, start + 86400 - 1)
    data = po(c, 102)
    assert data['current_period'] == 0 and data['spent_current_period'] == '30' and data['remaining'] == '70'
    # Advance the chain during the read: every registry field must still describe its captured block.
    original_events = chain.events
    def moving_events(to_block='latest'):
        jump(chain, start + 86400)
        return original_events(to_block)
    with monkeypatch.context() as patch:
        patch.setattr(chain, 'events', moving_events)
        snapshot = chain.registry()
    data = next(p for p in snapshot['pos'] if p['po_id'] == 102)
    assert data['current_period'] == 0 and data['remaining'] == '70' and data['spent_current_period'] == '30'
    data = po(c, 102)
    assert data['current_period'] == 1 and data['spent_current_period'] == '0' and data['remaining'] == '100'
    assert data['total_paid'] == '30'
    assert chain.contract.functions.purchaseOrders(102).call()[2] == 30 * 10**18
    assert chain.w3.eth.get_balance(chain.contract.address) == 470 * 10**18
    jump(chain, start + 3 * 86400)
    assert po(c, 102)['remaining'] == '100' and po(c, 102)['total_paid'] == '30'
    owner(c, {'type': 'closePO', 'poId': 102})
    assert po(c, 102)['remaining'] == '0' and po(c, 102)['total_paid'] == '30'


def test_demo_interface_http_reasons_and_history(client):
    c, chain, _ = client
    queue_vendor(c, chain); queue_po(c, chain)
    assert invoice(c, 8, 102, 'INTERFACE-PAID', '10')['tx']['reason_code'] == 0
    outcomes = [(invoice(c, 7, 102, 'WRONG-VENDOR'), 12, 'POVendorMismatch')]
    owner(c, {'type': 'closePO', 'poId': 102})
    outcomes.append((invoice(c, 8, 102, 'CLOSED'), 13, 'POClosed'))
    queue_po(c, chain, pid=103)
    owner(c, {'type': 'deactivateVendor', 'vendorId': 8})
    outcomes.append((invoice(c, 8, 103, 'INACTIVE'), 11, 'VendorInactive'))
    for attempt, code, name in outcomes:
        saved = c.get('/api/attempts/' + attempt['id']).json()
        assert saved['tx']['reason_code'] == code and saved['tx']['reason'] == name
        row = next(e for e in c.get('/api/ledger?kind=blocked').json() if e['tx_hash'] == attempt['tx']['hash'])
        assert row['reason_code'] == code and row['reason'] == name
        print(f'HTTP -> saved receipt -> ledger: {code} / {name}; BLOCKED')
    assert chain.w3.eth.get_balance(chain.contract.address) == 490 * 10**18
    assert po(c, 102)['total_paid'] == '10' and po(c, 102)['remaining'] == '0'
    print('Vault = 490; PO-102 paid history = 10; all three rejections leave balances unchanged')


def test_po_query_expiry_keeps_once_paid_history(client):
    c, chain, _ = client
    assert invoice(c, 7, 101, 'EXPIRES', '10')['outcome'] == 'paid'
    jump(chain, chain.contract.functions.poExpiry().call())
    data = po(c, 101)
    assert data['remaining'] == '0' and data['current_period'] == 0
    assert data['spent_current_period'] == data['total_paid'] == '10'
    assert not data['closed']


def test_multiple_po_raises_and_cancel_are_isolated(client):
    c, chain, _ = client
    queue_vendor(c, chain); queue_po(c, chain)
    for pid, cap in [(101, '600'), (102, '120')]:
        owner(c, {'type': 'queue', 'kind': 'RaisePOBudget', 'decoded': {'po_id': pid, 'new_cap': cap}})
    p1, p2 = pending(c, 101), pending(c, 102)
    assert len(c.get('/api/registry').json()['pending_changes']) == 2
    owner(c, {'type': 'cancel', 'id': p1['id']})
    assert c.get('/api/registry').json()['pending_changes'] == [p2]
    assert po(c, 101)['pending_budget_change_id'] is None
    assert po(c, 102)['pending_budget_change_id'] == p2['id']


def test_new_budget_input_validation_sends_nothing(client):
    c, chain, _ = client
    before = chain.w3.eth.block_number
    for pid in [-1, 2**53, '1.5']:
        owner(c, {'type': 'queue', 'kind': 'RaisePOBudget', 'decoded': {'po_id': pid, 'new_cap': '600'}}, 409)
    for pid in [True, 101.5]:
        response = c.post('/api/local/owner', json={'type': 'queue', 'kind': 'RaisePOBudget', 'decoded': {'po_id': pid, 'new_cap': '600'}})
        assert response.status_code == 422
    for cap in ['NaN', '-1', '0.0000000000000000001']:
        owner(c, {'type': 'lowerPOBudget', 'poId': 101, 'cap': cap}, 409)
    assert c.post('/api/local/owner', json={'type': 'lowerPOBudget', 'poId': True, 'cap': '1'}).status_code == 422
    assert chain.w3.eth.block_number == before
