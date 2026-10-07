"""Empty deployment bootstrap on isolated Anvil, including its actual HTTP adapter."""
import importlib.util
import json
import socket
import subprocess
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from web3 import Web3
from app.chain.local import LocalChain
from app.main import create_app
from test_local_integration import invoice, owner

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope='module')
def runtime():
    spec = importlib.util.spec_from_file_location('initialization_runtime', ROOT / 'scripts/local_runtime.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope='module')
def node(runtime):
    with socket.socket() as socket_:
        socket_.bind(('127.0.0.1', 0)); port = socket_.getsockname()[1]
    rpc = f'http://127.0.0.1:{port}'
    proc = subprocess.Popen([str(ROOT / '.tools/anvil'), '--host', '127.0.0.1', '--port', str(port),
                             '--chain-id', '31337', '--silent', '--no-cors'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        w3 = Web3(Web3.HTTPProvider(rpc))
        runtime.wait_for(w3.is_connected, [proc])
        yield runtime, w3, rpc
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()


@pytest.fixture
def isolated(node):
    runtime, w3, rpc = node
    snapshot = w3.provider.make_request('evm_snapshot', [])['result']
    yield runtime, w3, rpc
    w3.provider.make_request('evm_revert', [snapshot])


@pytest.fixture
def empty_client(isolated, tmp_path, monkeypatch):
    runtime, w3, rpc = isolated
    manifest = runtime.deploy(rpc, 'empty-integration', mode='empty')
    path = tmp_path / 'chain.json'; path.write_text(json.dumps(manifest))
    monkeypatch.setenv('COUNTERSIGN_LOCAL_MANIFEST', str(path))
    app = create_app(tmp_path / 'data')
    with TestClient(app, base_url='http://127.0.0.1:8000') as client:
        yield client, app.state.local_chain, manifest


def test_empty_bootstrap_receipts_prove_two_delayed_stages(empty_client):
    c, chain, manifest = empty_client
    w3, f = chain.w3, chain.contract.functions
    assert manifest['initialization_mode'] == 'empty'
    assert manifest['initial_state'] == {'vendor_count': 0, 'po_count': 0, 'daily_limit': 0,
                                       'balance': 0, 'paused': True, 'agent': '0x'+'0'*40, 'authorized_agents': []}
    deployment = w3.eth.get_transaction(manifest['deployment_tx'])
    assert deployment['value'] == 0
    # Inspect historical on-chain state, independently of the recorded initial_state.
    block = manifest['deployment_block']
    assert f.vendorCount().call(block_identifier=block) == f.poCount().call(block_identifier=block) == 0
    assert f.dailyLimit().call(block_identifier=block) == 0
    assert f.paused().call(block_identifier=block)
    assert w3.eth.get_balance(chain.contract.address, block) == 0
    assert f.agent().call() == '0x'+'0'*40
    for account in manifest['agents'].values():
        assert not f.authorizedAgents(account).call(block_identifier=block)
        assert f.authorizedAgents(account).call()
    transactions = manifest['initialization_transactions']
    assert len(transactions) == 17  # Eight approvals + eight executions + independent funding.
    queues = {t['change_id']: t for t in transactions if t['action'].startswith('queue:')}
    assert len(queues) == 8
    for t in transactions:
        receipt = w3.eth.get_transaction_receipt(t['tx_hash'])
        assert receipt['status'] == 1 and receipt['blockNumber'] == t['block']
        assert w3.eth.get_block(t['block'])['timestamp'] == t['timestamp']
        if t['action'].startswith('execute:'):
            q = queues[t['change_id']]
            assert q['execute_after'] == q['timestamp'] + 120
            assert t['timestamp'] >= q['execute_after']
            decoded = chain.decode(receipt['logs'])
            assert any(Web3.to_hex(args.get('changeId', b'')) == t['change_id'] for _, args, _ in decoded)
    vendor_executions = [t for t in transactions if t['action'].startswith('execute:vendor:')]
    po_queues = [t for t in transactions if t['action'].startswith('queue:po:')]
    assert min(t['block'] for t in po_queues) > max(t['block'] for t in vendor_executions)
    registry = c.get('/api/registry').json()
    assert len(registry['vendors']) == len(registry['pos']) == 2
    assert registry['vault_balance'] == '500' and registry['daily_cap'] == '200'
    assert not registry['paused'] and registry['pending_changes'] == []
    assert f.totalBudget().call() == 500 * 10**18 and f.poExpiry().call() > block


def test_demo_empty_script_then_http_two_vendor_payment(empty_client):
    c, chain, manifest = empty_client
    print('Script: deployed empty (0 vendors / 0 POs / 0 funds / no Agent permission / paused)')
    print('Script: executed two 120s initialization stages; no pending approvals; funded 500')
    first = invoice(c, 7, 101, 'EMPTY-FIRST', '30', agent='guarded')
    second = invoice(c, 8, 102, 'EMPTY-SECOND', '20')
    assert first['outcome'] == second['outcome'] == 'paid'
    assert first['tx']['reason_code'] == second['tx']['reason_code'] == 0
    assert first['proposal']['pay_to'] != second['proposal']['pay_to']
    mismatch = invoice(c, 7, 102, 'EMPTY-MISMATCH')
    assert mismatch['tx']['reason_code'] == 12
    duplicate = invoice(c, 7, 101, 'EMPTY-FIRST', '30')
    assert duplicate['tx']['reason_code'] == 6
    registry = c.get('/api/registry').json()
    pos = {p['po_id']:p for p in registry['pos']}
    assert pos[101]['remaining'] == '470' and pos[102]['remaining'] == '80'
    assert pos[101]['total_paid'] == '30' and pos[102]['total_paid'] == '20'
    assert registry['vault_balance'] == '450' and registry['remaining_today'] == '150'
    assert chain.contract.functions.totalPaid().call() == 50 * 10**18
    print('HTTP: paid 30 / 20; PO-101 remaining 470; PO-102 remaining 80; vault 450; daily spent 50')
    owner(c, {'type':'closePO','poId':102})
    owner(c, {'type':'deactivateVendor','vendorId':7})
    assert invoice(c, 8, 102, 'EMPTY-CLOSED')['tx']['reason_code'] == 13
    assert invoice(c, 7, 101, 'EMPTY-INACTIVE')['tx']['reason_code'] == 11
    assert c.get('/api/registry').json()['vault_balance'] == '450'
    print('HTTP: cross-vendor / duplicate / closed / inactive rejected; balance and history retained')


def test_bootstrapped_new_ui_queue_still_waits_full_delay(empty_client):
    c, chain, _ = empty_client
    owner(c, {'type':'queue','kind':'RaisePOBudget','decoded':{'po_id':102,'new_cap':'120'}})
    p = c.get('/api/registry').json()['pending_changes'][0]
    assert not p['ready']
    record = chain.contract.functions.poBudgetChanges(p['id']).call()
    qtime = chain.w3.eth.get_block('latest')['timestamp']
    assert record[-2] == qtime + 120
    owner(c, {'type':'execute','id':p['id']}, 409)
    chain.w3.provider.make_request('evm_setNextBlockTimestamp', [record[-2]-1])
    chain.w3.provider.make_request('evm_mine', [])
    assert not c.get('/api/registry').json()['pending_changes'][0]['ready']
    chain.w3.provider.make_request('evm_setNextBlockTimestamp', [record[-2]])
    chain.w3.provider.make_request('evm_mine', [])
    assert c.get('/api/registry').json()['pending_changes'][0]['ready']
    owner(c, {'type':'execute','id':p['id']})
    assert chain.contract.functions.purchaseOrders(102).call()[1] == 120 * 10**18


def test_preset_mode_retains_original_defaults(isolated, tmp_path):
    runtime, w3, rpc = isolated
    m = runtime.deploy(rpc, 'preset-compatibility')
    path = tmp_path / 'chain.json'; path.write_text(json.dumps(m))
    chain = LocalChain(path)
    registry = chain.registry()
    assert m['initialization_mode'] == 'demo' and m['initial_state'] is None
    assert len(registry['vendors']) == len(registry['pos']) == 1
    assert registry['vault_balance'] == '500' and registry['daily_cap'] == '200'
    assert chain.contract.functions.agent().call() == m['agents']['guarded']
    assert len(m['initialization_transactions']) == 2


@pytest.mark.parametrize('rpc', ['https://127.0.0.1:8545', 'http://example.invalid:8545'])
def test_initializer_rejects_nonlocal_rpc_before_connection(runtime, rpc):
    with pytest.raises(RuntimeError, match='本地 RPC'): runtime.deploy(rpc, 'invalid', mode='empty')


def test_failed_initialization_never_returns_a_ready_manifest(isolated, monkeypatch):
    runtime, w3, rpc = isolated
    def fail_time(_): raise RuntimeError('simulated initialization failure')
    monkeypatch.setattr(runtime, 'advance_initialization', fail_time)
    with pytest.raises(RuntimeError, match='simulated initialization failure'):
        runtime.deploy(rpc, 'failed', mode='empty')


@pytest.mark.parametrize('command, mode', [('start','demo'),('start-empty','empty')])
def test_start_reuses_only_matching_mode(runtime, tmp_path, monkeypatch, capsys, command, mode):
    current = tmp_path / 'current.json'
    current.write_text(json.dumps({'pid':1,'run_id':'test','initialization_mode':mode}))
    monkeypatch.setattr(runtime, 'STATE', tmp_path)
    monkeypatch.setattr(runtime, 'CURRENT', current)
    monkeypatch.setattr(runtime, 'running', lambda _:True)
    monkeypatch.setattr(runtime.sys, 'argv', ['local_runtime.py', command])
    # This path must return before checking/starting any service or touching existing children.
    monkeypatch.setattr(runtime, 'available', lambda _:pytest.fail('must reuse existing mode'))
    runtime.main()
    assert '已运行' in capsys.readouterr().out
    opposite = 'empty' if mode == 'demo' else 'demo'
    current.write_text(json.dumps({'pid':1,'run_id':'test','initialization_mode':opposite}))
    with pytest.raises(RuntimeError, match='不会自动停止当前链'): runtime.main()
    assert json.loads(current.read_text())['initialization_mode'] == opposite


def test_clock_offsets_match_number_of_simulated_waits(runtime):
    assert runtime.initialization_delay('demo') == 120
    assert runtime.initialization_delay('empty') == 240
    with pytest.raises(RuntimeError, match='未知'): runtime.initialization_delay('unknown')


@pytest.mark.parametrize('path, mode', [
    ('/old/黑松客/countersign', ''),
    ('/new/黑客松/countersign', ' demo'),
    ('/a directory/countersign', ' empty'),
])
def test_running_recognizes_supervisor_after_directory_rename(runtime, monkeypatch, path, mode):
    command = f'{path}/.venv/bin/python {path}/scripts/local_runtime.py serve saved-run{mode}\n'
    def ps(args, **kwargs):
        assert args == ['ps','-p','8020','-o','command=']
        return subprocess.CompletedProcess(args, 0, stdout=command)
    monkeypatch.setattr(runtime.subprocess, 'run', ps)
    assert runtime.running({'pid':8020,'run_id':'saved-run'})


@pytest.mark.parametrize('command', [
    '/usr/bin/python /old/scripts/local_runtime.py serve saved-run-other',
    '/usr/bin/python /old/scripts/local_runtime.py serve other-run saved-run',
    '/usr/bin/python /old/scripts/local_runtime.py status saved-run',
    '/usr/bin/python /old/scripts/unrelated.py serve saved-run',
    '/usr/bin/node /old/scripts/local_runtime.py serve saved-run',
    '/usr/bin/python /old/scripts/local_runtime.py serve saved-run extra',
])
def test_running_rejects_unrelated_or_reused_pid(runtime, monkeypatch, command):
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k:subprocess.CompletedProcess(a,0,stdout=command))
    assert not runtime.running({'pid':8020,'run_id':'saved-run'})


def test_running_rejects_exited_and_invalid_pid(runtime, monkeypatch):
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k:subprocess.CompletedProcess(a,1,stdout=''))
    assert not runtime.running({'pid':8020,'run_id':'saved-run'})
    for meta in ({}, {'pid':0,'run_id':'saved-run'}, {'pid':'bad','run_id':'saved-run'}, {'pid':1,'run_id':''}):
        assert not runtime.running(meta)


def test_frontend_bridge_has_its_own_exact_process_role(runtime, monkeypatch):
    base = '/usr/bin/python /renamed/scripts/local_runtime.py recover-frontend '
    for suffix, expected in [('saved-run',True), ('saved-run-extra',False), ('saved-run demo',False)]:
        monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k:subprocess.CompletedProcess(a,0,stdout=base+suffix))
        assert runtime.running({'pid':8020,'run_id':'saved-run'}) is expected


def test_bridge_stop_closes_replacement_before_resuming_original(runtime, monkeypatch):
    events = []
    class Child:
        def poll(self): return None
        def terminate(self): events.append('stop-ui')
        def wait(self, timeout): events.append('ui-exited')
    monkeypatch.setattr(runtime.os, 'kill', lambda pid, sig:events.append((pid,sig)))
    runtime.finish_frontend_recovery(8020,[Child()])
    assert events == ['stop-ui','ui-exited',(8020,runtime.signal.SIGTERM),(8020,runtime.signal.SIGCONT)]


def test_recovery_rejects_another_run_without_signalling(runtime, tmp_path, monkeypatch):
    current = tmp_path/'current.json'
    current.write_text(json.dumps({'pid':8020,'run_id':'different'}))
    monkeypatch.setattr(runtime,'CURRENT',current)
    monkeypatch.setattr(runtime.os,'kill',lambda *_:pytest.fail('must not signal another run'))
    with pytest.raises(RuntimeError,match='不匹配'): runtime.recover_frontend('saved-run')


def test_serve_command_passes_empty_mode(runtime, tmp_path, monkeypatch):
    monkeypatch.setattr(runtime, 'STATE', tmp_path)
    monkeypatch.setattr(runtime, 'CURRENT', tmp_path / 'current.json')
    monkeypatch.setattr(runtime.sys, 'argv', ['local_runtime.py','serve','new-run','empty'])
    calls = []
    monkeypatch.setattr(runtime, 'serve', lambda run_id, mode:calls.append((run_id,mode)))
    runtime.main()
    assert calls == [('new-run','empty')]


def test_serve_initialization_failure_closes_its_node_and_never_starts_http(runtime, tmp_path, monkeypatch):
    monkeypatch.setattr(runtime, 'STATE', tmp_path)
    monkeypatch.setattr(runtime, 'available', lambda _:None)
    monkeypatch.setattr(runtime.signal, 'signal', lambda *_:None)
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *_, **__:None)
    children, commands = [], []
    class Child:
        stopped = False
        def poll(self): return 0 if self.stopped else None
        def terminate(self): self.stopped = True
        def wait(self, **_): return 0
    def start(command, **_):
        commands.append(command); child=Child(); children.append(child); return child
    monkeypatch.setattr(runtime.subprocess, 'Popen', start)
    def fail(*_, **__): raise RuntimeError('simulated bootstrap failure')
    monkeypatch.setattr(runtime, 'deploy', fail)
    with pytest.raises(RuntimeError, match='simulated bootstrap failure'): runtime.serve('failed-run','empty')
    assert len(children) == 1 and children[0].stopped
    assert Path(commands[0][0]).name == 'anvil'
    assert not (tmp_path/'failed-run'/'ready').exists()


def test_wall_clock_pacing_after_empty_bootstrap(runtime):
    # Match serve's block-time=1 setup on an independent random port; startup output is suppressed.
    with socket.socket() as socket_:
        socket_.bind(('127.0.0.1',0)); port = socket_.getsockname()[1]
    rpc = f'http://127.0.0.1:{port}'
    proc = subprocess.Popen([str(ROOT / '.tools/anvil'),'--host','127.0.0.1','--port',str(port),
                             '--chain-id','31337','--timestamp',str(int(time.time())-runtime.initialization_delay('empty')),
                             '--block-time','1','--silent','--no-cors'], stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        m = runtime.deploy(rpc, 'clock-pacing', mode='empty')
        w3 = Web3(Web3.HTTPProvider(rpc))
        assert abs(w3.eth.get_block('latest')['timestamp'] - time.time()) <= 5
        address = m['contract_address']
        from app.chain.local import artifact
        contract = w3.eth.contract(address=address, abi=artifact()['abi'])
        queued = w3.eth.wait_for_transaction_receipt(contract.functions.queuePOBudgetIncrease(102,120*10**18).transact({'from':m['owner_address']}))
        event = contract.events.POBudgetChangeQueued().process_receipt(queued)[0]['args']
        assert event['executeAfter'] - w3.eth.get_block(queued['blockNumber'])['timestamp'] == 120
        assert 115 <= event['executeAfter'] - time.time() <= 125
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
