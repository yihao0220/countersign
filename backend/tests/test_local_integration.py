"""Real HTTP -> SQLite -> Anvil -> contract receipt regression tests; no public RPC."""
import importlib.util
import json
import socket
import subprocess
import time
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from web3 import Web3
from app.chain.local import LocalChain, units, money
from app.api.local import initialize
from app.main import create_app

ROOT = Path(__file__).resolve().parents[2]

@pytest.fixture(scope='module')
def node(tmp_path_factory):
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    proc=subprocess.Popen([str(ROOT/'.tools/anvil'),'--host','127.0.0.1','--port',str(port),'--chain-id','31337','--no-cors','--silent'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        spec=importlib.util.spec_from_file_location('local_runtime',ROOT/'scripts/local_runtime.py')
        runtime=importlib.util.module_from_spec(spec); spec.loader.exec_module(runtime)
        manifest=runtime.deploy(f'http://127.0.0.1:{port}','integration-tests')
        path=tmp_path_factory.mktemp('chain')/'chain.json'; path.write_text(json.dumps(manifest))
        chain=LocalChain(path)
        yield chain,path
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()

@pytest.fixture
def client(node,tmp_path,monkeypatch):
    chain,path=node
    snap=chain.w3.provider.make_request('evm_snapshot',[])['result']
    monkeypatch.setenv('COUNTERSIGN_LOCAL_MANIFEST',str(path))
    app=create_app(tmp_path)
    with TestClient(app,base_url='http://127.0.0.1:8000') as c: yield c,chain,app
    chain.w3.provider.make_request('evm_revert',[snap])


def submit(c,*,demo=None,text=None,agent='naive'):
    data={'agent':agent,'nickname':'integration-test'}
    if demo: data['demo']=demo
    else: data['text']=text
    r=c.post('/api/team/attempts',data=data); assert r.status_code==202,r.text
    r=c.get('/api/attempts/'+r.json()['attempt_id']); assert r.status_code==200,r.text
    return r.json()


def owner(c,body,code=200):
    r=c.post('/api/local/owner',json=body); assert r.status_code==code,r.text
    return r.json()


def test_normal_receipt_and_actual_balances(client):
    c,chain,_=client
    f=chain.contract.functions
    before=chain.w3.eth.get_balance(f.payout().call())
    a=submit(c,demo='normal',agent='guarded')
    assert a['outcome']=='paid',a
    assert a['tx']['event']=='Paid' and a['tx']['network']=='local'
    assert f.remainingBudget().call()==400*10**18
    assert f.spentToday().call()==100*10**18
    assert chain.w3.eth.get_balance(f.payout().call())-before==100*10**18
    assert c.get(a['tx']['explorer_url']).json()['events'][0]['name']=='Paid'
    assert c.get('/api/registry').json()['vault_balance']=='400'
    assert c.get('/api/ledger?kind=paid').json()[0]['tx_hash']==a['tx']['hash']
    assert len(c.get('/api/team/attempts').json())==1
    assert c.get('/api/stats').json()['seed']['attempts']==1

@pytest.mark.parametrize('demo,reason',[('wrong-address','PayoutMismatch'),('over-budget','OverBudget'),('daily-limit','DailyLimitExceeded')])
def test_policy_blocks_do_not_spend(client,demo,reason):
    c,chain,_=client
    a=submit(c,demo=demo)
    assert a['outcome']=='blocked',a
    assert a['tx']['reason']==reason
    assert chain.w3.eth.get_transaction_receipt(a['tx']['hash'])['status']==1
    assert chain.contract.functions.remainingBudget().call()==500*10**18
    assert chain.contract.functions.totalSpent().call()==0


def test_both_agents_share_invoice_identity(client):
    c,chain,_=client
    first=submit(c,demo='normal',agent='guarded')
    second=submit(c,demo='duplicate',agent='naive')
    assert first['outcome']=='paid'
    assert second['tx']['reason']=='DuplicateInvoice'
    assert first['proposal']['invoice_hash']==second['proposal']['invoice_hash']
    assert chain.contract.functions.totalSpent().call()==100*10**18


def test_pause_wait_execute_then_pay(client):
    c,chain,_=client
    owner(c,{'type':'pause'})
    a=submit(c,demo='normal'); assert a['tx']['reason']=='Paused'
    owner(c,{'type':'queue','kind':'Unpause','decoded':{}})
    pending=c.get('/api/registry').json()['pending_changes'][0]
    assert not pending['ready']
    owner(c,{'type':'execute','id':pending['id']},409)
    assert chain.contract.functions.paused().call()
    chain.w3.provider.make_request('evm_increaseTime',[120]); chain.w3.provider.make_request('evm_mine',[])
    assert c.get('/api/registry').json()['pending_changes'][0]['ready']
    owner(c,{'type':'execute','id':pending['id']})
    owner(c,{'type':'execute','id':pending['id']},409)
    assert submit(c,demo='normal')['outcome']=='paid'


def test_payout_queue_cancel_and_execute(client):
    c,chain,_=client
    original=chain.contract.functions.payout().call()
    owner(c,{'type':'queue','kind':'SetPayout','decoded':{'vendor_id':7,'new_payout':chain.manifest['wrong_payout']}})
    p=c.get('/api/registry').json()['pending_changes'][0]
    owner(c,{'type':'cancel','id':p['id']})
    owner(c,{'type':'execute','id':p['id']},409)
    assert chain.contract.functions.payout().call()==original
    owner(c,{'type':'queue','kind':'SetPayout','decoded':{'vendor_id':7,'new_payout':chain.manifest['wrong_payout']}})
    p=c.get('/api/registry').json()['pending_changes'][0]
    chain.w3.provider.make_request('evm_increaseTime',[120]); chain.w3.provider.make_request('evm_mine',[])
    owner(c,{'type':'execute','id':p['id']})
    assert chain.contract.functions.payout().call()==chain.manifest['wrong_payout']
    assert submit(c,text=json.dumps({'invoice_number':'OLD','amount':'10','pay_to':original}))['tx']['reason']=='PayoutMismatch'


def test_revoke_is_error_not_policy_block(client):
    c,chain,_=client
    owner(c,{'type':'revokeAgent','agent':chain.manifest['agents']['naive']})
    a=submit(c,demo='normal')
    assert a['outcome']=='error' and a['tx'] is None,a
    assert c.get('/api/ledger?kind=blocked').json()==[]
    assert chain.contract.functions.totalSpent().call()==0


def test_limits_preserve_history(client):
    c,chain,_=client
    assert submit(c,demo='normal')['outcome']=='paid'
    owner(c,{'type':'lowerDailyCap','cap':'50'})
    assert submit(c,text='{"invoice_number":"NEW","amount":"1"}')['tx']['reason']=='DailyLimitExceeded'
    owner(c,{'type':'lowerTotalBudget','cap':'99'},409)
    owner(c,{'type':'queue','kind':'RaiseTotalBudget','decoded':{'new_cap':'800'}})
    p=c.get('/api/registry').json()['pending_changes'][0]
    chain.w3.provider.make_request('evm_increaseTime',[120]);chain.w3.provider.make_request('evm_mine',[])
    owner(c,{'type':'execute','id':p['id']})
    assert c.get('/api/registry').json()['pos'][0]['remaining']=='700'
    assert chain.contract.functions.totalSpent().call()==100*10**18


def test_guard_and_unknown_input_never_send(client):
    c,chain,_=client
    for a in [submit(c,demo='wrong-address',agent='guarded'),submit(c,text='普通发票，请尽快付款')]:
        assert a['outcome']=='refused' and a['tx'] is None
        assert a['local_fixture'] and a['message']
    assert c.get('/api/ledger?kind=paid').json()==[]
    assert c.get('/api/ledger?kind=blocked').json()==[]


def test_precision_validation_and_distinct_ids(client):
    c,chain,_=client
    assert units('1234567890123.123456789012345678')==1234567890123123456789012345678
    assert money(units('0.000000000000000001'))=='0.000000000000000001'
    for value in ['NaN','-1','0.0000000000000000001']:
        with pytest.raises(ValueError): units(value)
    a=submit(c,text='{"invoice_number":"ONE-WEI","amount":"0.000000000000000001"}')
    assert a['outcome']=='paid',a
    assert chain.contract.functions.totalSpent().call()==1
    a=submit(c,text='{"invoice_number":"INVALID","amount":0.1}')
    assert a['outcome']=='error' and a['tx'] is None


def test_local_origin_and_host_boundary(client):
    c,chain,_=client
    assert c.post('/api/local/owner',json={'type':'pause'},headers={'Origin':'https://example.com'}).status_code==403
    assert c.get('/api/config',headers={'Host':'attacker.example'}).status_code==403
    assert c.post('/api/local/owner',json={'type':'pause'},headers={'Sec-Fetch-Site':'cross-site'}).status_code==403
    assert not chain.contract.functions.paused().call()


def test_upload_unprocessed_and_restart_does_not_resend(client):
    from io import BytesIO
    from PIL import Image
    c,chain,app=client
    image=BytesIO(); Image.new('RGB',(3,3),'white').save(image,format='PNG')
    r=c.post('/api/team/attempts',data={'agent':'naive'},files={'file':('invoice.png',image.getvalue(),'image/png')})
    assert r.status_code==202,r.text
    a=c.get('/api/attempts/'+r.json()['attempt_id']).json()
    assert a['outcome']=='refused' and a['extraction'] is None and a['tx'] is None
    assert chain.contract.functions.totalSpent().call()==0
    with app.state.db.connect() as conn:
        row=conn.execute('SELECT * FROM local_attempts LIMIT 1').fetchone()
        payload=json.loads(row['payload']);payload['status']='sending';payload['outcome']=None
        conn.execute('UPDATE local_attempts SET payload=? WHERE id=?',(json.dumps(payload),row['id']))
    initialize(app.state.db)
    assert c.get('/api/attempts/'+a['id']).json()['status']=='error'
    assert chain.contract.functions.totalSpent().call()==0


def test_batch_persists_results_and_uses_actual_contract(client):
    c,chain,app=client
    r=c.post('/api/team/batch',json={'folder':'clean'})
    assert r.status_code==202
    url='/api/team/batch/'+r.json()['batch_id']
    result=c.get(url).json()
    assert (result['total'],result['done'],result['paid'],result['false_alarms'])==(3,3,3,0)
    assert chain.contract.functions.totalSpent().call()==3*10**18
    rows=c.get('/api/team/attempts?source=batch&limit=2').json()
    assert len(rows)==2 and all(a['source']=='batch' for a in rows)
    assert all(isinstance(a['extraction']['amount_total'],(int,float)) for a in rows)
    initialize(app.state.db)
    assert c.get(url).json()==result
    assert c.get('/api/team/batch/missing').status_code==404
    assert c.post('/api/team/batch',json={'folder':'../unknown'}).status_code==422


def test_batch_reports_real_blocks_without_claiming_ai_false_alarms(client):
    c,chain,_=client
    owner(c,{'type':'pause'})
    r=c.post('/api/team/batch',json={'folder':'clean'})
    result=c.get('/api/team/batch/'+r.json()['batch_id']).json()
    assert (result['done'],result['blocked'],result['paid'],result['false_alarms'])==(3,3,0,0)
    assert chain.contract.functions.totalSpent().call()==0


def test_owner_tx_receipt_validation_is_read_only(client):
    c,chain,_=client
    paid=submit(c,demo='normal')
    assert c.post('/api/team/owner-tx',json={'tx_hash':paid['tx']['hash']}).status_code==409
    owner(c,{'type':'pause'})
    h=c.get('/api/ledger?kind=changes').json()[0]['tx_hash']
    before=chain.w3.eth.block_number
    for _ in range(2):
        r=c.post('/api/team/owner-tx',json={'tx_hash':h})
        assert r.status_code==200,r.text
        assert r.json()['events'][0]['name']=='Paused'
    assert chain.w3.eth.block_number==before
    assert c.post('/api/team/owner-tx',json={'tx_hash':'0x'+'f'*64}).status_code==404
    assert c.post('/api/team/owner-tx',json={'tx_hash':'bad'}).status_code==422


@pytest.mark.parametrize('extension',['png','pdf'])
def test_uploaded_document_preview_is_rendered_not_paid(client,extension):
    from io import BytesIO
    from PIL import Image
    import pymupdf
    c,chain,_=client
    if extension=='png':
        output=BytesIO(); Image.new('RGB',(1600,800),'red').save(output,format='PNG'); content=output.getvalue()
    else:
        with pymupdf.open() as pdf:
            page=pdf.new_page(); page.insert_text((70,70),'PREVIEW TEST'); content=pdf.tobytes()
    r=c.post('/api/team/attempts',data={'agent':'guarded'},files={'file':('invoice.'+extension,content)})
    assert r.status_code==202,r.text
    a=c.get('/api/attempts/'+r.json()['attempt_id']).json()
    assert a['outcome']=='refused' and a['tx'] is None
    result=c.get(a['preview_url']); assert result.status_code==200,result.text[:100] if result.status_code!=200 else ''
    assert result.headers['content-type']=='image/png'
    with Image.open(BytesIO(result.content)) as img:
        assert max(img.size)<=1201
        if extension=='png': assert img.getpixel((100,100))==(255,0,0)
    assert chain.contract.functions.totalSpent().call()==0
    assert c.get('/api/attempts/missing/preview.png').status_code==404


def test_filter_applied_before_limit(client):
    c,_,_=client
    first=submit(c,demo='normal')
    c.post('/api/bounty/attempts',data={'agent':'naive','demo':'wrong-address'})
    rows=c.get('/api/team/attempts?source=team&limit=1').json()
    assert [a['id'] for a in rows]==[first['id']]


def test_original_vite_proxy_localhost_is_accepted(client):
    c,_,_=client
    r=c.get('/api/config',headers={'host':'localhost:8000','origin':'http://127.0.0.1:5173'})
    assert r.status_code==200
    assert c.get('/api/config',headers={'host':'attacker.example'}).status_code==403


def execute_change(c,chain,kind):
    change=next(p for p in c.get('/api/registry').json()['pending_changes'] if p['kind']==kind)
    owner(c,{'type':'execute','id':change['id']},409)
    chain.w3.provider.make_request('evm_increaseTime',[120]); chain.w3.provider.make_request('evm_mine',[])
    return owner(c,{'type':'execute','id':change['id']})


def queue_vendor(c,chain,vid=8):
    recipient=chain.w3.eth.accounts[5]
    owner(c,{'type':'queue','kind':'AddVendor','decoded':{'vendor_id':vid,'payout':recipient}})
    execute_change(c,chain,'AddVendor')
    return recipient


def queue_po(c,chain,pid=102,vid=8,days=0):
    from datetime import datetime,timezone,timedelta
    expiry=(datetime.fromtimestamp(chain.w3.eth.get_block('latest')['timestamp'],timezone.utc)+timedelta(days=20)).strftime('%Y-%m-%d')
    owner(c,{'type':'queue','kind':'AddPO','decoded':{'po_id':pid,'vendor_id':vid,'cap':'100','expiry':expiry,'period_days':days}})
    execute_change(c,chain,'AddPO')


def invoice(c,vid,pid,name,amount='1',agent='naive'):
    return submit(c,text=json.dumps({'invoice_number':name,'vendor_id':vid,'po_id':pid,'amount':amount}),agent=agent)


def test_original_page_vendor_po_close_deactivate_actions(client):
    c,chain,_=client
    recipient=queue_vendor(c,chain)
    vendor=next(v for v in c.get('/api/registry').json()['vendors'] if v['id']==8)
    assert vendor['active'] and vendor['payout']==recipient
    queue_po(c,chain)
    a=invoice(c,8,102,'NEW-1','10',agent='guarded')
    assert a['outcome']=='paid',a
    assert a['proposal']['pay_to']==recipient
    pos=c.get('/api/registry').json()['pos']
    assert next(p for p in pos if p['po_id']==102)['remaining']=='90'
    assert next(p for p in pos if p['po_id']==101)['remaining']=='500'
    wrong=invoice(c,7,102,'WRONG-PO'); assert wrong['tx']['reason']=='POVendorMismatch'
    owner(c,{'type':'closePO','poId':102})
    closed=invoice(c,8,102,'CLOSED'); assert closed['tx']['reason']=='POClosed'
    queue_po(c,chain,pid=103)
    owner(c,{'type':'deactivateVendor','vendorId':8})
    inactive=invoice(c,8,103,'INACTIVE'); assert inactive['tx']['reason']=='VendorInactive'
    r=c.get('/api/registry').json()
    assert not next(v for v in r['vendors'] if v['id']==8)['active']
    assert next(p for p in r['pos'] if p['po_id']==102)['closed']
    assert r['vault_balance']=='490' and r['remaining_today']=='190'
    events=c.get('/api/ledger?kind=changes').json()
    assert any(e['name']=='POClosed' for e in events)
    assert any(e['name']=='VendorDeactivated' for e in events)


def test_original_page_withdrawal_receipt_and_balances(client):
    c,chain,_=client
    owner(c,{'type':'queue','kind':'Withdraw','decoded':{'amount':'25'}})
    pending=next(p for p in c.get('/api/registry').json()['pending_changes'] if p['kind']=='Withdraw')
    assert pending['decoded']['amount']=='25'
    tx=execute_change(c,chain,'Withdraw')
    r=c.post('/api/team/owner-tx',json={'tx_hash':tx['hash']})
    assert r.status_code==200,r.text
    e=r.json()['events'][0]
    assert e['name']=='WithdrawalExecuted'
    assert e['args']['payTo']==chain.manifest['owner_address'] and e['args']['amount']==25*10**18
    assert chain.w3.eth.get_balance(chain.contract.address)==475*10**18
    assert chain.contract.functions.totalPaid().call()==0
    assert chain.contract.functions.spentToday().call()==0
    owner(c,{'type':'execute','id':pending['id']},409)
    assert c.get('/api/registry').json()['pending_changes']==[]


@pytest.mark.parametrize('kind,decoded',[
    ('AddVendor',{'vendor_id':8,'payout':'0x000000000000000000000000000000000000000D'}),
    ('AddPO',{'po_id':102,'vendor_id':7,'cap':'1','expiry':'2099-12-31','period_days':0}),
    ('Withdraw',{'amount':'1'}),
])
def test_new_queue_cancel_and_replay_api(client,kind,decoded):
    c,chain,_=client
    owner(c,{'type':'queue','kind':kind,'decoded':decoded})
    pending=next(p for p in c.get('/api/registry').json()['pending_changes'] if p['kind']==kind)
    owner(c,{'type':'cancel','id':pending['id']})
    chain.w3.provider.make_request('evm_increaseTime',[120]); chain.w3.provider.make_request('evm_mine',[])
    owner(c,{'type':'execute','id':pending['id']},409)
    assert c.get('/api/registry').json()['pending_changes']==[]
    assert chain.w3.eth.get_balance(chain.contract.address)==500*10**18


def test_multivendor_payout_adapter_and_periodic_budget(client):
    c,chain,_=client
    queue_vendor(c,chain); queue_po(c,chain,days=1)
    recipient=chain.w3.eth.accounts[6]
    owner(c,{'type':'queue','kind':'SetPayout','decoded':{'vendor_id':8,'new_payout':recipient}})
    pending=next(p for p in c.get('/api/registry').json()['pending_changes'] if p['kind']=='SetPayout')
    assert pending['decoded']['vendor_id']==8
    execute_change(c,chain,'SetPayout')
    a=invoice(c,8,102,'PERIOD-1','100',agent='guarded')
    assert a['outcome']=='paid' and a['tx']['hash']
    assert a['proposal']['pay_to']==recipient
    assert invoice(c,8,102,'PERIOD-2')['tx']['reason']=='OverBudget'
    chain.w3.provider.make_request('evm_increaseTime',[86400]); chain.w3.provider.make_request('evm_mine',[])
    assert next(p for p in c.get('/api/registry').json()['pos'] if p['po_id']==102)['remaining']=='100'
    assert invoice(c,8,102,'PERIOD-1','100')['tx']['reason']=='DuplicateInvoice'
    assert invoice(c,8,102,'PERIOD-2')['outcome']=='paid'


def test_new_admin_input_validation_does_not_send_transaction(client):
    c,chain,_=client
    before=chain.w3.eth.block_number
    base={'po_id':102,'vendor_id':7,'cap':'1','expiry':'2099-12-31','period_days':0}
    for field,value in [('expiry','invalid'),('expiry','2026-02-30'),('period_days','1.2'),('period_days',2**32),('po_id',-1)]:
        d=base|{field:value}
        owner(c,{'type':'queue','kind':'AddPO','decoded':d},409)
    assert c.post('/api/local/owner',json={'type':'closePO','poId':True}).status_code==422
    assert chain.w3.eth.block_number==before
