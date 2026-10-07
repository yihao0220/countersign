#!/usr/bin/env python3
"""Start/stop this checkout's loopback-only integration, never a public chain."""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from urllib.parse import urlparse
from pathlib import Path
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.runtime'
CURRENT = STATE / 'current.json'
NODE_FALLBACK = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'


def wait_for(check, children=(), timeout=30):
    end = time.monotonic()+timeout
    while time.monotonic()<end:
        if any(c.poll() is not None for c in children): raise RuntimeError('子服务退出，请查看 .runtime 下本次运行日志')
        try:
            if check(): return
        except Exception: pass
        time.sleep(.15)
    raise RuntimeError('等待本地服务超时')


def available(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try: sock.bind(('127.0.0.1',port))
        except OSError: raise RuntimeError(f'本机端口 {port} 已占用；不会关闭其他程序') from None


def initialization_delay(mode):
    if mode not in ('demo', 'empty'): raise RuntimeError('未知本地初始化模式')
    return 240 if mode == 'empty' else 120


def advance_initialization(w3):
    # Called only after deploy has verified the loopback Anvil endpoint.
    for method, params in [('evm_increaseTime', [120]), ('evm_mine', [])]:
        if 'error' in w3.provider.make_request(method, params):
            raise RuntimeError('本地初始化推进时间失败')


def deploy(rpc, run_id, frontend='http://127.0.0.1:5173', *, mode='demo'):
    from web3 import Web3
    from web3.logs import DISCARD
    from app.chain.local import artifact
    initialization_delay(mode)
    endpoint = urlparse(rpc)
    if endpoint.scheme != 'http' or endpoint.hostname != '127.0.0.1' or endpoint.username or endpoint.password:
        raise RuntimeError('拒绝部署：只允许 127.0.0.1 本地 RPC')
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={'timeout':5}))
    wait_for(w3.is_connected)
    if w3.eth.chain_id!=31337 or not w3.client_version.lower().startswith('anvil'):
        raise RuntimeError('拒绝部署：只允许本机 Anvil 31337')
    accounts = w3.eth.accounts
    a = artifact()
    factory = w3.eth.contract(abi=a['abi'],bytecode=a['bytecode']['object'])
    owner, guarded, naive, payout, wrong = accounts[:5]
    expiry = w3.eth.get_block('latest')['timestamp']+30*86400
    args = (guarded, payout, 500*10**18, expiry, 200*10**18)
    if mode == 'empty': args = ('0x'+'0'*40, '0x'+'0'*40, 0, 0, 0)
    tx = factory.constructor(*args).transact({'from':owner,'value':0 if mode == 'empty' else 500*10**18,'gas':6000000})
    receipt = w3.eth.wait_for_transaction_receipt(tx)
    if receipt['status']!=1: raise RuntimeError('本地合约创建失败')
    contract = w3.eth.contract(address=receipt['contractAddress'],abi=a['abi'])
    f = contract.functions
    transactions = []
    def send(call, action, event=None, change=None):
        r = w3.eth.wait_for_transaction_receipt(call.transact({'from':owner,'gas':1500000}))
        if r['status'] != 1: raise RuntimeError('本地初始化交易失败：' + action)
        record = {'action':action,'tx_hash':Web3.to_hex(r['transactionHash']),
                  'block':r['blockNumber'],'timestamp':w3.eth.get_block(r['blockNumber'])['timestamp']}
        if change is not None: record['change_id'] = Web3.to_hex(change)
        if event:
            logs = getattr(contract.events,event)().process_receipt(r, errors=DISCARD)
            if len(logs) != 1: raise RuntimeError('初始化回执没有唯一预期事件：' + event)
            change = logs[0]['args']['changeId']
            record.update(change_id=Web3.to_hex(change),execute_after=logs[0]['args']['executeAfter'])
            if record['execute_after'] != record['timestamp'] + 120:
                raise RuntimeError('初始化等待时间与合约不匹配')
        transactions.append(record)
        return change
    def execute_all(changes):
        advance_initialization(w3)
        for change, action in changes:
            send(f.execute(change), 'execute:' + action, change=change)
    initial_state = None
    if mode == 'empty':
        initial_state = {'vendor_count':f.vendorCount().call(),'po_count':f.poCount().call(),
                         'daily_limit':f.dailyLimit().call(),'balance':w3.eth.get_balance(contract.address),
                         'paused':f.paused().call(),'agent':f.agent().call(),
                         'authorized_agents':[account for account in accounts if f.authorizedAgents(account).call()]}
        if initial_state != {'vendor_count':0,'po_count':0,'daily_limit':0,'balance':0,
                             'paused':True,'agent':'0x'+'0'*40,'authorized_agents':[]}:
            raise RuntimeError('空金库初始状态不符合约定')
        first = []
        for vid, recipient in [(7,payout),(8,accounts[5])]:
            first.append((send(f.queueAddVendor(vid,recipient),f'queue:vendor:{vid}','VendorQueued'),f'vendor:{vid}'))
        for label, account in [('guarded',guarded),('naive',naive)]:
            first.append((send(f.queueAgentAuthorization(account),'queue:agent:'+label,'AgentAuthorizationQueued'),'agent:'+label))
        first.append((send(f.queueLimitIncrease(1,200*10**18),'queue:daily','LimitChangeQueued'),'daily'))
        execute_all(first)
        if not all(tuple(f.vendors(vid).call()[1:]) == (True,True) for vid in (7,8)):
            raise RuntimeError('供应商初始化失败')
        second = []
        plans = [(101,7,500*10**18,expiry,0),(102,8,100*10**18,expiry+335*86400,30)]
        for plan in plans:
            second.append((send(f.queueAddPO(*plan),f'queue:po:{plan[0]}','POQueued'),f'po:{plan[0]}'))
        second.append((send(f.queueResume(),'queue:resume','ResumeQueued'),'resume'))
        funding = w3.eth.wait_for_transaction_receipt(w3.eth.send_transaction({'from':owner,'to':contract.address,'value':500*10**18,'gas':100000}))
        if funding['status'] != 1: raise RuntimeError('本地初始化充值失败')
        transactions.append({'action':'fund','tx_hash':Web3.to_hex(funding['transactionHash']),
                             'block':funding['blockNumber'],'timestamp':w3.eth.get_block(funding['blockNumber'])['timestamp']})
        execute_all(second)
        for pid, vid, cap, deadline, days in plans:
            po = f.purchaseOrders(pid).call()
            if (po[0],po[1],po[4],po[5],po[8],po[9]) != (vid,cap,deadline,days,False,True):
                raise RuntimeError('采购单初始化失败')
        if (f.poCount().call()!=2 or f.vendorCount().call()!=2 or f.paused().call()
                or f.dailyLimit().call()!=200*10**18 or f.payout().call()!=payout
                or f.totalBudget().call()!=500*10**18 or f.remainingBudget().call()!=500*10**18
                or f.poExpiry().call()!=expiry or f.totalPaid().call()!=0
                or w3.eth.get_balance(contract.address)!=500*10**18):
            raise RuntimeError('金库初始化最终状态不符合约定')
    else:
        change = send(f.queueAgentAuthorization(naive),'queue:agent:naive','AgentAuthorizationQueued')
        execute_all([(change,'agent:naive')])
    if not all(f.authorizedAgents(account).call() for account in (guarded,naive)):
        raise RuntimeError('本地 Agent 初始化失败')
    return {'run_id':run_id,'rpc_url':rpc,'frontend_url':frontend,'chain_id':31337,
            'owner_address':owner,'agents':{'guarded':guarded,'naive':naive},'payout':payout,'wrong_payout':wrong,
            'contract_address':receipt['contractAddress'],'deployment_tx':Web3.to_hex(tx),
            'deployment_block':receipt['blockNumber'],'deployment_block_hash':receipt['blockHash'].hex(),
            'initialization_mode':mode,'initial_state':initial_state,'initialization_transactions':transactions}


def running(meta):
    try:
        pid = int(meta['pid'])
        run_id = meta['run_id']
    except (KeyError, TypeError, ValueError):
        return False
    if pid <= 0 or not isinstance(run_id, str) or not run_id:
        return False
    result = subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
    # Parent directories can be renamed while this process is alive. Match the
    # Python supervisor's exact role and run ID, never an arbitrary substring.
    command = (r'(?:.+/)?python(?:\d+(?:\.\d+)*)?\s+'
               r'.+/scripts/local_runtime\.py\s+serve\s+' + re.escape(run_id)
               + r'(?:\s+(?:demo|empty))?')
    return result.returncode == 0 and re.fullmatch(command, result.stdout.strip()) is not None


def serve(run_id, mode='demo'):
    delay = initialization_delay(mode)
    children=[]
    run = STATE/run_id
    run.mkdir(parents=True,exist_ok=True)
    def stop(*_): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,stop)
    signal.signal(signal.SIGINT,stop)
    try:
        for p in (8545,8000,5173,3000): available(p)
        anvil=ROOT/'.tools/anvil'
        node=shutil.which('node') or (str(NODE_FALLBACK) if NODE_FALLBACK.exists() else None)
        vite=ROOT/'frontend/node_modules/vite/bin/vite.js'
        if not anvil.exists() or not node or not vite.exists(): raise RuntimeError('缺少本地依赖，请按 docs/LOCAL_TEST.md 安装')
        subprocess.run([str(ROOT/'.tools/forge'),'build','--root',str(ROOT/'contracts')],check=True)
        # Suppress Anvil startup output because it includes disposable private keys.
        children.append(subprocess.Popen([str(anvil),'--host','127.0.0.1','--port','8545','--chain-id','31337','--timestamp',str(int(time.time())-delay),'--no-cors','--block-time','1','--silent'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL))
        manifest=deploy('http://127.0.0.1:8545',run_id,mode=mode)
        manifest_path=run/'chain.json'
        manifest_path.write_text(json.dumps(manifest,indent=2))
        env=dict(os.environ,COUNTERSIGN_LOCAL_MANIFEST=str(manifest_path),BACKEND_DATA_DIR=str(run/'data'),VITE_API_MODE='live',
                 COUNTERSIGN_AUTH_URL='http://127.0.0.1:3000',COUNTERSIGN_BACKEND_URL='http://127.0.0.1:8000',
                 APP_ORIGIN='http://127.0.0.1:5173',HOST='127.0.0.1',PORT='3000',SECURE_COOKIES='false',DATA_DIR=str(STATE/'accounts'))
        for key in ['HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy']: env.pop(key,None)
        env['NO_PROXY']='127.0.0.1,localhost'
        env['NODE_OPTIONS']='--dns-result-order=ipv4first'
        backend_log=(run/'backend.log').open('w')
        frontend_log=(run/'frontend.log').open('w')
        auth_log=(run/'auth.log').open('w')
        children.append(subprocess.Popen([node,str(ROOT/'auth/server.mjs')],cwd=ROOT/'auth',env=env,stdout=auth_log,stderr=subprocess.STDOUT))
        children.append(subprocess.Popen([sys.executable,'-m','uvicorn','app.main:app','--host','127.0.0.1','--port','8000'],cwd=ROOT/'backend',env=env,stdout=backend_log,stderr=subprocess.STDOUT))
        children.append(subprocess.Popen([node,str(vite),'--host','127.0.0.1','--port','5173','--strictPort','--mode','integration'],cwd=ROOT/'frontend',env=env,stdout=frontend_log,stderr=subprocess.STDOUT))
        wait_for(lambda: json.load(urllib.request.urlopen('http://127.0.0.1:3000/api/auth-health',timeout=2))['ok'],children)
        wait_for(lambda: json.load(urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=2))['workspace_auth'],children)
        wait_for(lambda: urllib.request.urlopen('http://127.0.0.1:5173/',timeout=2).status == 200,children)
        (run/'ready').write_text('ready\n')
        print('本地测试版已启动：http://127.0.0.1:5173/ （首页 → 登录 → 工作台）',flush=True)
        while all(c.poll() is None for c in children): time.sleep(.5)
        raise RuntimeError('一个本地服务已退出，正在停止本次其余服务')
    except KeyboardInterrupt: pass
    finally:
        for c in children:
            if c.poll() is None: c.terminate()
        for c in children:
            try: c.wait(timeout=5)
            except subprocess.TimeoutExpired: c.kill(); c.wait()
        (run/'ready').unlink(missing_ok=True)


def main():
    command=sys.argv[1] if len(sys.argv)>1 else 'start'
    STATE.mkdir(exist_ok=True)
    meta=json.loads(CURRENT.read_text()) if CURRENT.exists() else None
    if command=='serve': return serve(sys.argv[2],sys.argv[3] if len(sys.argv)>3 else 'demo')
    if command=='stop':
        if meta and running(meta):
            os.kill(meta['pid'],signal.SIGTERM)
            wait_for(lambda: not running(meta),timeout=15)
            print('本次本地服务已停止；运行记录保留在 .runtime/')
        else: print('本项目没有正在运行的本地服务')
        return
    if command=='status':
        print('运行中：http://127.0.0.1:5173/' if meta and running(meta) and (STATE/meta['run_id']/'ready').exists() else '未运行')
        if meta and running(meta) and not meta.get('workspace_auth'):
            print('当前为旧实例，尚未加载本次登录服务；不会自动重启或清空现有链。')
        return
    if command not in ('start','start-empty'): raise RuntimeError('用法：./local.sh start|start-empty|stop|status')
    mode = 'empty' if command == 'start-empty' else 'demo'
    if meta and running(meta):
        if meta.get('initialization_mode','demo') != mode:
            raise RuntimeError('已有另一种初始化模式正在运行；如需切换，请先自行运行 ./local.sh stop。不会自动停止当前链。')
        print('已运行：http://127.0.0.1:5173/')
        if not meta.get('workspace_auth'):
            print('旧实例未加载登录服务；请先保存需要的演示结果，再自行 stop/start。新启动会创建新链。')
        return
    for p in (8545,8000,5173,3000): available(p)
    run_id=time.strftime('%Y%m%d-%H%M%S')+'-'+uuid4().hex[:8]
    run=STATE/run_id
    run.mkdir()
    with (run/'runtime.log').open('w') as log:
        child=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'serve',run_id,mode],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    CURRENT.write_text(json.dumps({'pid':child.pid,'run_id':run_id,'initialization_mode':mode,'workspace_auth':True}))
    try: wait_for(lambda:(run/'ready').exists(),[child],timeout=45)
    except Exception:
        if child.poll() is None: child.terminate()
        raise RuntimeError(f'启动未成功，请查看 {run}/runtime.log 和 backend.log') from None
    if mode == 'empty': print('模式：从空金库完成时间锁初始化；两轮等待由 Anvil 模拟。')
    print('本地测试版：http://127.0.0.1:5173/\n流程：首页 → 注册/登录 → 工作台\n停止：./local.sh stop\n仅本机 Anvil，未连接公链；本次启动使用全新测试账本。')

if __name__=='__main__':
    try: main()
    except Exception as exc: print(str(exc),file=sys.stderr); sys.exit(1)
