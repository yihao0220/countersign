"""Compatibility API joining the supplied frontend to the supplied backend and local contract."""
import json
import re
import time
from io import BytesIO
from pathlib import Path
from PIL import Image, ImageOps
import pymupdf
from pydantic import BaseModel
from typing import Literal
from fastapi.responses import Response
from datetime import datetime, timezone
from threading import RLock
from uuid import uuid4
from fastapi import APIRouter, Request, HTTPException, BackgroundTasks, Query
from web3 import Web3
from app.services.invoice_service import create_submission, save_upload
from app.local_models import Attempt, Accepted, LocalAction
from app.chain.local import units, money

router = APIRouter(prefix='/api')
SCHEMA = '''
CREATE TABLE IF NOT EXISTS local_attempts (
 id TEXT PRIMARY KEY, submission_id TEXT NOT NULL, source TEXT NOT NULL, device TEXT NOT NULL,
 created_at TEXT NOT NULL, payload TEXT NOT NULL, broadcast_hash TEXT
);
CREATE TABLE IF NOT EXISTS local_batches (id TEXT PRIMARY KEY, attempt_ids TEXT NOT NULL);
'''
DEMO = [
 ('normal','正常付款','Normal payment','LOCAL-001','100','registered'),
 ('wrong-address','错误收款地址','Wrong payout','LOCAL-002','25','wrong'),
 ('over-budget','超出总预算','Over total budget','LOCAL-003','501','registered'),
 ('daily-limit','超出每日限额','Over daily limit','LOCAL-004','201','registered'),
 ('duplicate','重复 LOCAL-001 账单','Repeat LOCAL-001','LOCAL-001','100','registered'),
]
PROCESS_LOCK = RLock()


def service(request):
    return request.app.state.local_chain, request.app.state.db


def initialize(db):
    with db.connect() as conn:
        conn.executescript(SCHEMA)
        # Never blindly replay a payment following process interruption.
        for row in conn.execute('SELECT id,payload,broadcast_hash FROM local_attempts').fetchall():
            a = json.loads(row['payload'])
            if a['status'] not in ('done','error'):
                a.update(status='error', outcome='error', message='处理进程已中断；需核对本地账本，不自动重发付款。')
                conn.execute('UPDATE local_attempts SET payload=? WHERE id=?', (json.dumps(a), row['id']))


def save(db, attempt):
    Attempt.model_validate(attempt)
    with db.connect() as conn:
        conn.execute('UPDATE local_attempts SET payload=? WHERE id=?', (json.dumps(attempt), attempt['id']))
        if attempt['status'] in ('done', 'error'):
            sid = attempt['_submission_id']
            extraction = attempt.get('extraction')
            stored = dict(extraction, amount=extraction.get('amount_total')) if extraction else None
            conn.execute('UPDATE submissions SET status=?,extracted=? WHERE id=?',
                         ('failed' if attempt['status']=='error' else 'completed', json.dumps(stored) if stored else None, sid))
            status = {'refused':'needs_review','error':'failed'}.get(attempt['outcome'], attempt['outcome'])
            tx = attempt.get('tx')
            conn.execute('INSERT OR REPLACE INTO agent_runs(submission_id,agent,guard_version,status,flags,decision,tx_hash,chain_outcome) VALUES(?,?,?,?,?,?,?,?)',
                         (sid,attempt['agent'],'local-rules-v1',status,json.dumps(attempt['flags']),
                          'submit_payment' if tx else 'error' if status=='failed' else 'review',
                          tx['hash'] if tx else None,json.dumps(tx) if tx else None))


def fixture(chain, name):
    record = next((d for d in DEMO if d[0] == name), None)
    if not record: raise ValueError('未知测试样例')
    return {'invoice_number': record[3], 'vendor_id': 7, 'po_id': 101, 'amount': record[4],
            'pay_to': chain.manifest['wrong_payout'] if record[5] == 'wrong' else chain.contract.functions.payout().call()}


def parse_input(chain, text):
    text = text.strip()
    if text in ('正常','normal','clean'): return fixture(chain, 'normal')
    try: value = json.loads(text)
    except (ValueError, TypeError): return None
    if not isinstance(value, dict): return None
    if not all(k in value for k in ('invoice_number','amount')): return None
    invoice = str(value['invoice_number']).strip()
    if not invoice or len(invoice) > 120: raise ValueError('账单编号需要 1–120 个字符')
    if isinstance(value['amount'], (float, bool)): raise ValueError('金额请用字符串，如 "100.25"')
    value['amount'] = money(units(value['amount']))
    value['invoice_number'] = invoice
    for key, default in [('vendor_id',7),('po_id',101)]:
        v = value.get(key, default)
        if isinstance(v, bool) or not re.fullmatch(r'\d{1,77}', str(v)) or int(v) >= 2**256:
            raise ValueError('供应商和采购单编号必须是非负整数')
        value[key] = int(v)
    value['pay_to'] = Web3.to_checksum_address(value.get('pay_to') or chain.contract.functions.vendors(value['vendor_id']).call()[0])
    return value


def process(chain, db, attempt, text, demo):
    with PROCESS_LOCK:
        start = time.monotonic()
        try:
            data = fixture(chain, demo) if demo else parse_input(chain, text or '')
            if data is None:
                attempt.update(status='done', outcome='refused', message='待人工核对：本版本未连接 AI。请使用本地样例或填写结构化账单。')
                attempt['steps'][0].update(status='skipped', detail=attempt['message'])
                for step in attempt['steps'][1:]: step.update(status='skipped')
                save(db, attempt)
                return
            payout = chain.contract.functions.vendors(data['vendor_id']).call()[0]
            amount = money(units(data['amount']))
            # Shared across both agents, submissions, and payout edits. JSON canonicalization prevents delimiter collisions.
            identity = json.dumps([str(data['vendor_id']), data['invoice_number'].strip(), str(units(amount))], separators=(',',':'), ensure_ascii=False)
            invoice_hash = Web3.to_hex(Web3.keccak(text=identity))
            proposal = {'vendor_id': data['vendor_id'], 'vendor_name': '本地测试供应商' if data['vendor_id']==7 else f'供应商 #{data["vendor_id"]}', 'pay_to': data['pay_to'],
                        'registry_payout': payout, 'po_id': data['po_id'], 'po_ref': f'PO-{data["po_id"]}',
                        'amount': amount, 'invoice_hash': invoice_hash}
            attempt['proposal'] = proposal
            attempt['extraction'] = {'is_invoice': True, 'vendor_name': '本地测试供应商' if data['vendor_id']==7 else f'供应商 #{data["vendor_id"]}', 'invoice_number': data['invoice_number'],
                'invoice_date': None, 'due_date': None, 'currency': 'LOCAL', 'amount_total': float(amount),
                'po_reference': proposal['po_ref'], 'payee_address': proposal['pay_to'], 'notes_to_payer': None,
                'language': 'zh', 'visible_text': json.dumps(data, ensure_ascii=False)}
            attempt['steps'][0].update(status='done', detail='结构化测试输入；未调用 AI 或 OCR')
            attempt['steps'][1].update(status='skipped', detail='未运行隐藏文本检测')
            attempt['steps'][2].update(status='done', detail='已读取本地合约登记地址')
            attempt.update(status='deciding')
            if attempt['agent'] == 'guarded' and proposal['pay_to'].lower() != payout.lower():
                attempt['steps'][3].update(status='done', detail='本地确定性规则拒绝不匹配地址；不是模型判断')
                attempt['steps'][4].update(status='skipped')
                attempt['flags'].append({'code':'PAYOUT_CHANGED','severity':'high','detail_en':'Payout mismatch','detail_zh':'收款地址不符'})
                attempt.update(status='done', outcome='refused', message='本地防护规则已拒绝，未向合约申请付款。')
            else:
                attempt['steps'][3].update(status='done' if attempt['agent']=='guarded' else 'skipped', detail='本地测试规则，无模型调用')
                attempt['steps'][4].update(status='running')
                attempt['status'] = 'sending'
                save(db, attempt)
                def broadcast(tx):
                    with db.connect() as conn: conn.execute('UPDATE local_attempts SET broadcast_hash=? WHERE id=?', (tx, attempt['id']))
                tx = chain.payment(proposal, attempt['agent'], broadcast)
                attempt['tx'] = tx
                attempt['steps'][4].update(status='done', detail=tx['event'] + (': ' + tx['reason_label_zh'] if tx['reason'] else ''))
                attempt.update(status='done', outcome='paid' if tx['event']=='Paid' else 'blocked', message='本地合约实际回执；虚拟资金。')
            attempt['latency_ms'] = int((time.monotonic() - start) * 1000)
            save(db, attempt)
        except Exception as exc:
            attempt.update(status='error', outcome='error', message='本地处理失败：' + str(exc)[:240])
            for step in attempt['steps']:
                if step['status'] == 'running': step.update(status='failed', detail=attempt['message'])
            save(db, attempt)


@router.get('/config')
def config(request: Request):
    chain, _ = service(request)
    chain.check()
    m = chain.manifest
    return {'network':'local','chain_id':31337,'rpc_url':m['rpc_url'],'explorer_url':'/api/local',
            'contract_address':m['contract_address'],'token':{'address':'0x'+'0'*40,'symbol':'LOCAL','decimals':18},
            'owner_address':m['owner_address'],'agents':m['agents'],'public_base_url':m['frontend_url'],
            'timelock_seconds':120,'bounty_network':'local','local_fixture':True,'run_id':m['run_id']}


@router.get('/registry')
def registry(request: Request): return service(request)[0].registry()


@router.get('/ledger')
def ledger(request: Request, kind: str=Query('all',pattern='^(all|paid|blocked|changes)$'), limit: int=Query(100,ge=1,le=500)):
    try: return service(request)[0].ledger(kind,limit)
    except ValueError as exc: raise HTTPException(409, str(exc)) from None


@router.get('/team/attempts', response_model=list[Attempt])
def attempts(request: Request, source: Literal['all','team','bounty','batch','seed']='all', limit: int=Query(100,ge=1,le=500)):
    _, db = service(request)
    with db.connect() as conn:
        rows = conn.execute("SELECT payload FROM local_attempts WHERE (? = 'all' OR source=?) ORDER BY created_at DESC LIMIT ?", (source,source,limit)).fetchall()
    return [json.loads(row['payload']) for row in rows]


@router.get('/attempts/{aid}',response_model=Attempt)
def attempt(request: Request, aid: str):
    _, db = service(request)
    with db.connect() as conn: row = conn.execute('SELECT payload FROM local_attempts WHERE id=?',(aid,)).fetchone()
    if not row: raise HTTPException(404,'没有这条本地记录')
    return json.loads(row['payload'])


async def submit(request, background, source):
    chain, db = service(request)
    form = await request.form(max_files=1,max_fields=8,max_part_size=110000)
    agent = str(form.get('agent','guarded'))
    if agent not in ('guarded','naive'): raise HTTPException(422,'Agent 必须是 guarded 或 naive')
    nickname, text, demo = str(form.get('nickname','')), form.get('text'), form.get('demo')
    file = form.get('file')
    if len(nickname)>100 or (text is not None and (not isinstance(text,str) or len(text)>100000)):
        raise HTTPException(422,'输入过长')
    if sum(bool(x) for x in (text,demo,file)) != 1: raise HTTPException(422,'请提交文字、文件或一个测试样例')
    if demo and demo not in {d[0] for d in DEMO}: raise HTTPException(422,'未知测试样例')
    if file:
        try: saved = await save_upload(db,request.app.state.upload_dir,file,nickname)
        finally: await file.close()
    else: saved = create_submission(db,nickname=nickname,text=text or ('local demo: '+demo))
    a = new_attempt(db, saved['id'], source, agent, nickname, file.filename if file else None, request.headers.get('X-Device-Id','local'))
    background.add_task(process,chain,db,a,text,demo)
    return {'attempt_id':a['id']}


def new_attempt(db, sid, source, agent, nickname, filename=None, device='local'):
    aid = uuid4().hex
    a = {'id':aid,'status':'queued','outcome':None,'agent':agent,'source':source,'nickname':nickname,
         'input_kind':'pdf' if filename and filename.lower().endswith('.pdf') else 'image' if filename else 'text',
         'file_name':filename,'preview_url':f'/api/attempts/{aid}/preview.png' if filename else None,'steps':[{'name':n,'status':'pending','detail':None} for n in ['extract','hidden_text','match','guard','chain']],
         'extraction':None,'hidden_text':None,'flags':[{'code':'LOCAL_FIXTURE','severity':'low','detail_en':'Local test rules; no AI model','detail_zh':'本地测试规则，未调用 AI 模型'}],
         'proposal':None,'tx':None,'ai_fooled':False,'created_at':datetime.now(timezone.utc).isoformat(),
         'local_fixture':True,'message':None,'_submission_id':sid}
    with db.connect() as conn:
        conn.execute("UPDATE jobs SET status='done' WHERE submission_id=?",(sid,))
        conn.execute('INSERT INTO local_attempts(id,submission_id,source,device,created_at,payload) VALUES(?,?,?,?,?,?)',
                     (aid,sid,source,device,a['created_at'],json.dumps(a)))
    return a


@router.post('/team/attempts',status_code=202,response_model=Accepted)
async def submit_team(request: Request, background: BackgroundTasks): return await submit(request,background,'team')


@router.post('/bounty/attempts',status_code=202,response_model=Accepted)
async def submit_bounty(request: Request, background: BackgroundTasks): return await submit(request,background,'bounty')


@router.get('/team/demo-invoices')
def demos():
    return [{'name':d[0],'kind':'clean' if d[0]=='normal' else 'poisoned','title_en':d[2],'title_zh':d[1],
             'note_en':'Structured local fixture. No AI or PDF extraction. Shared invoice identity across agents.',
             'note_zh':'结构化本地样例，不经过 AI/PDF 识别。两 Agent 共用账单防重记录。'} for d in DEMO]


@router.get('/stats')
def stats(request: Request):
    rows = attempts(request,limit=500)
    def block(source):
        selected = [a for a in rows if (a['source']=='bounty')==source]
        return {'attempts':len(selected),'people':len({a['nickname'] for a in selected if a['nickname']}),
                'guard_catches':0,'ai_fooled':{'guarded':0,'naive':0},
                'chain_blocks':sum(a['outcome']=='blocked' for a in selected),
                'paid_real_vendor_on_fake_invoice':'0','money_lost':'0'}
    return {'outside':block(True),'seed':block(False),'since':None}


@router.get('/leaderboard')
def leaderboard(): return []


@router.get('/eval')
def evaluation(): return {}


class BatchInput(BaseModel):
    folder: Literal['clean']


@router.post('/team/batch', status_code=202)
def batch(request: Request, data: BatchInput, background: BackgroundTasks):
    chain, db = service(request)
    bid = uuid4().hex
    work = []
    for index in range(3):
        text = json.dumps({'invoice_number':f'BATCH-{bid}-{index}', 'amount':'1'})
        saved = create_submission(db,nickname='本地批量样例',text=text)
        a = new_attempt(db,saved['id'],'batch','guarded','本地批量样例')
        work.append((a,text))
    with db.connect() as conn:
        conn.execute('INSERT INTO local_batches VALUES(?,?)',(bid,json.dumps([a['id'] for a,_ in work])))
    for a,text in work: background.add_task(process,chain,db,a,text,None)
    return {'batch_id':bid,'local_fixture':True}


@router.get('/team/batch/{bid}')
def batch_status(request: Request, bid: str):
    _,db = service(request)
    with db.connect() as conn:
        row = conn.execute('SELECT attempt_ids FROM local_batches WHERE id=?',(bid,)).fetchone()
        if not row: raise HTTPException(404,'没有这条批次记录')
        ids = json.loads(row['attempt_ids'])
        rows = [json.loads(conn.execute('SELECT payload FROM local_attempts WHERE id=?',(aid,)).fetchone()['payload']) for aid in ids]
    return {'total':len(rows),'done':sum(a['status'] in ('done','error') for a in rows),
            **{k:sum(a['outcome']==k for a in rows) for k in ('paid','refused','blocked','no_invoice','error')},
            'false_alarms':0,'local_fixture':True,'note':'结构化本地样例；未运行 AI 误报评测。'}


class OwnerTxInput(BaseModel):
    tx_hash: str


@router.post('/team/owner-tx')
def owner_tx(request: Request, data: OwnerTxInput):
    result = transaction(request,data.tx_hash)
    chain,_ = service(request)
    receipt = chain.w3.eth.get_transaction_receipt(data.tx_hash)
    # Execute is permissionless; accept an actual governance event, not an arbitrary payment.
    if receipt['status'] != 1 or not result['events'] or any(e['name'] in ('Paid','Blocked') for e in result['events']):
        raise HTTPException(409,'需要本地合约已成功执行的管理交易')
    return result


@router.get('/attempts/{aid}/preview.png')
def preview(request: Request, aid: str):
    _,db = service(request)
    with db.connect() as conn:
        row = conn.execute('SELECT s.document_path FROM submissions s JOIN local_attempts a ON a.submission_id=s.id WHERE a.id=?',(aid,)).fetchone()
    if not row or not row['document_path']: raise HTTPException(404,'此记录没有文件预览')
    path = Path(row['document_path']).resolve()
    if path.parent != request.app.state.upload_dir.resolve() or not path.is_file():
        raise HTTPException(404,'找不到上传文件')
    try:
        if path.suffix == '.pdf':
            with pymupdf.open(path) as pdf:
                page = pdf[0]
                longest = max(page.rect.width,page.rect.height)
                if longest <= 0: raise ValueError('Invalid page size')
                pix = page.get_pixmap(matrix=pymupdf.Matrix(1200/longest,1200/longest),alpha=False)
                content = pix.tobytes('png')
        else:
            with Image.open(path) as original:
                img = ImageOps.exif_transpose(original).convert('RGB')
                img.thumbnail((1200,1200))
                output = BytesIO(); img.save(output,format='PNG'); content=output.getvalue()
        return Response(content,media_type='image/png',headers={'Cache-Control':'private, max-age=3600','X-Content-Type-Options':'nosniff'})
    except Exception: raise HTTPException(422,'此文件无法生成预览') from None



@router.post('/local/owner')
def owner(request: Request, action: LocalAction):
    try: return service(request)[0].owner_action(action.model_dump(exclude_none=True))
    except Exception as exc: raise HTTPException(409,'操作未完成：'+str(exc)[:220]) from None


@router.get('/local/tx/{tx_hash}')
def transaction(request: Request, tx_hash: str):
    if not re.fullmatch(r'0x[0-9a-fA-F]{64}',tx_hash): raise HTTPException(422,'无效交易哈希')
    chain, _ = service(request)
    try:
        chain.check()
        r = chain.w3.eth.get_transaction_receipt(tx_hash)
        if r['to'] and r['to'].lower()!=chain.contract.address.lower(): raise ValueError()
        def plain(x):
            if isinstance(x,bytes): return Web3.to_hex(x)
            if isinstance(x,dict): return {k:plain(v) for k,v in x.items()}
            return x
        return {'network':'local','chain_id':31337,'run_id':chain.manifest['run_id'],'transaction_hash':tx_hash,
                'status':r['status'],'block_number':r['blockNumber'],
                'events':[{'name':name,'args':plain(args)} for name,args,_ in chain.decode(r['logs'])]}
    except Exception: raise HTTPException(404,'本次本地链没有该合约交易') from None


@router.get('/local/address/{address}')
def address_info(request: Request, address: str):
    if not re.fullmatch(r'0x[0-9a-fA-F]{40}', address): raise HTTPException(422,'无效地址')
    chain, _ = service(request)
    chain.check()
    account = Web3.to_checksum_address(address)
    return {'network':'local','chain_id':31337,'run_id':chain.manifest['run_id'],'address':account,
            'balance':money(chain.w3.eth.get_balance(account)), 'symbol':'LOCAL',
            'authorized_agent':chain.contract.functions.authorizedAgents(account).call(),
            'is_owner':account.lower()==chain.manifest['owner_address'].lower(),
            'is_vault':account.lower()==chain.contract.address.lower()}
