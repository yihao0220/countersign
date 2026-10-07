"""Only an ephemeral Anvil chain. No private keys and no public RPC support."""
import json
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path
from threading import RLock
from urllib.parse import urlparse
from datetime import datetime, timezone
import re
from web3 import Web3
from web3._utils.events import get_event_data
from eth_utils import event_abi_to_log_topic

ROOT = Path(__file__).resolve().parents[3]
REASON_CATALOG = json.loads((ROOT / 'contracts/interface/block-reasons.json').read_text(encoding='utf-8'))
if [r['code'] for r in REASON_CATALOG] != list(range(len(REASON_CATALOG))):
    raise ValueError('拒付接口定义的编码不连续')
REASONS = [r['name'] for r in REASON_CATALOG]
UNIT = 10**18
ZERO = b'\0' * 32


def reason_fields(code):
    if not isinstance(code, int) or not 0 <= code < len(REASON_CATALOG):
        raise ValueError('未知合约拒付编码：接口不匹配')
    r = REASON_CATALOG[code]
    return {'reason_code': code, 'reason': r['name'] if code else None,
            'reason_label_en': r['en'] if code else None, 'reason_label_zh': r['zh'] if code else None}


def natural(value, *, zero=False, maximum=2**53-1):
    if isinstance(value,bool) or not re.fullmatch(r'\d+',str(value)):
        raise ValueError('编号和周期必须是整数')
    number = int(value)
    if number < (0 if zero else 1) or number > maximum: raise ValueError('编号或周期超出范围')
    return number


def units(value):
    try:
        n = Decimal(str(value))
        if not n.is_finite() or n < 0 or n > Decimal(2**256 - 1) / UNIT:
            raise ValueError('金额超出范围')
        with localcontext() as context:
            context.prec = 100
            scaled = n * UNIT
        if scaled != scaled.to_integral_value():
            raise ValueError('金额最多支持 18 位小数')
        return int(scaled)
    except (InvalidOperation, TypeError):
        raise ValueError('金额必须是有效十进制数') from None


def money(value):
    # Integer arithmetic avoids rounding at the 18-decimal boundary.
    whole, fraction = divmod(int(value), UNIT)
    return str(whole) + ('.' + f'{fraction:018d}'.rstrip('0') if fraction else '')


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def artifact():
    return json.loads((ROOT / 'contracts/out/CountersignDemo.sol/CountersignDemo.json').read_text())


class LocalChain:
    def __init__(self, manifest):
        self.manifest = json.loads(Path(manifest).read_text())
        url = self.manifest['rpc_url']
        parsed = urlparse(url)
        if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.username or parsed.password:
            raise ValueError('只允许 127.0.0.1 本地 RPC')
        self.w3 = Web3(Web3.HTTPProvider(url, request_kwargs={'timeout': 10}))
        self.abi = artifact()['abi']
        self.contract = self.w3.eth.contract(address=self.manifest['contract_address'], abi=self.abi)
        self.lock = RLock()
        self.topics = {bytes(event_abi_to_log_topic(a)): a for a in self.abi if a.get('type') == 'event'}
        self.check()

    def check(self):
        if self.w3.eth.chain_id != 31337 or not self.w3.client_version.lower().startswith('anvil'):
            raise ValueError('必须使用 chain ID 31337 的 Anvil 本地链')
        if not self.w3.eth.get_code(self.contract.address):
            raise ValueError('本地合约不存在，请重新启动测试版')
        receipt = self.w3.eth.get_transaction_receipt(self.manifest['deployment_tx'])
        if receipt['blockHash'].hex() != self.manifest['deployment_block_hash']:
            raise ValueError('本地链已重置，请重新启动测试版')

    def decode(self, logs):
        result = []
        for log in logs:
            if log['address'].lower() != self.contract.address.lower() or not log['topics']:
                continue
            abi = self.topics.get(bytes(log['topics'][0]))
            if abi:
                decoded = get_event_data(self.w3.codec, abi, log)
                result.append((decoded['event'], dict(decoded['args']), log))
        return result

    def send(self, function, account, on_broadcast=lambda tx: None):
        with self.lock:
            self.check()
            tx = function.transact({'from': account, 'gas': 1500000})
            tx_hash = Web3.to_hex(tx)
            on_broadcast(tx_hash)
            receipt = self.w3.eth.wait_for_transaction_receipt(tx, timeout=20)
            if receipt['status'] != 1:
                raise ValueError('合约拒绝执行：请检查权限、待执行状态或时间锁')
            return tx_hash, receipt

    def payment(self, proposal, agent, on_broadcast):
        account = self.manifest['agents'][agent]
        function = self.contract.functions.pay(proposal['vendor_id'], proposal['pay_to'], proposal['po_id'],
                                               units(proposal['amount']), proposal['invoice_hash'])
        tx, receipt = self.send(function, account, on_broadcast)
        events = [(n, a) for n, a, _ in self.decode(receipt['logs']) if n in ('Paid', 'Blocked')]
        if len(events) != 1:
            raise ValueError('回执没有唯一付款结果')
        name, args = events[0]
        if (args['vendorId'] != proposal['vendor_id'] or args['poId'] != proposal['po_id']
                or args['payTo'].lower() != proposal['pay_to'].lower() or args['amount'] != units(proposal['amount'])
                or Web3.to_hex(args['invoiceHash']).lower() != proposal['invoice_hash'].lower()
                or args['agent'].lower() != account.lower()):
            raise ValueError('付款回执与申请不一致')
        reason = args.get('reason', 0)
        if name == 'Blocked' and reason == 0:
            raise ValueError('Blocked 不能使用 None 编码：接口不匹配')
        return {'hash': tx, 'explorer_url': '/api/local/tx/' + tx, 'event': name,
                **reason_fields(reason), 'network': 'local'}

    def events(self, to_block='latest'):
        self.check()
        logs = self.w3.eth.get_logs({'address': self.contract.address,
                                    'fromBlock': self.manifest['deployment_block'], 'toBlock': to_block})
        return self.decode(logs)

    def registry(self):
        with self.lock:
            f = self.contract.functions
            self.check()
            snapshot = self.w3.eth.get_block('latest')
            block, now = snapshot['number'], snapshot['timestamp']
            def read(function):
                return function.call(block_identifier=block)
            events = self.events(block)
            pending, accounts = [], dict(self.manifest['agents'])
            seen = set()
            for name, a, _ in events:
                cid = a.get('changeId')
                kind, decoded, state = None, {}, None
                if name == 'PayoutChangeQueued':
                    state = read(f.payoutChanges(cid))
                    kind, decoded = 'SetPayout', {'vendor_id': a['vendorId'], 'new_payout': state[0]}
                elif name == 'ResumeQueued':
                    state = read(f.resumeChanges(cid))
                    kind = 'Unpause'
                elif name == 'LimitChangeQueued':
                    state = read(f.limitChanges(cid))
                    kind = 'RaiseDailyCap' if state[0] == 1 else 'RaisePOBudget'
                    decoded = {'new_cap': money(state[1])}
                    if state[0] == 0: decoded['po_id'] = 101
                elif name == 'POBudgetChangeQueued':
                    if a['poId'] == 101:
                        state = read(f.limitChanges(cid))
                        new_cap = state[1]
                    else:
                        state = read(f.poBudgetChanges(cid))
                        new_cap = state[1]
                    kind, decoded = 'RaisePOBudget', {'po_id': a['poId'], 'new_cap': money(new_cap)}
                elif name == 'AgentAuthorizationQueued':
                    state = read(f.agentAuthorizations(cid))
                    kind, decoded = 'AddAgent', {'agent': state[0]}
                    if state[0] not in accounts.values(): accounts[state[0]] = state[0]
                elif name == 'VendorQueued':
                    state = read(f.vendorChanges(cid))
                    kind, decoded = 'AddVendor', {'vendor_id':state[0], 'payout':state[1]}
                elif name == 'POQueued':
                    state = read(f.poChanges(cid))
                    kind, decoded = 'AddPO', {'po_id':state[0], 'vendor_id':state[1], 'cap':money(state[2]), 'expiry':iso(state[3]), 'period_days':state[4]}
                elif name == 'WithdrawalQueued':
                    state = read(f.withdrawalChanges(cid))
                    kind, decoded = 'Withdraw', {'amount':money(state[0])}
                if state and state[-1] == 1 and cid not in seen:
                    seen.add(cid)
                    pending.append({'id': Web3.to_hex(cid), 'kind': kind, 'decoded': decoded,
                                    'eta': iso(state[-2]), 'ready': now >= state[-2]})
            vendors, pos = [], []
            for index in range(read(f.vendorCount())):
                vid = read(f.vendorIds(index))
                payout, _, active = read(f.vendors(vid))
                vendors.append({'id':vid, 'name_en':'Local supplier' if vid==7 else f'Supplier #{vid}',
                                'name_zh':'本地测试供应商' if vid==7 else f'供应商 #{vid}', 'payout':payout, 'active':active})
            for index in range(read(f.poCount())):
                pid = read(f.poIds(index))
                po = read(f.purchaseOrders(pid))
                period = (now - po[6]) // (po[5] * 86400) if po[5] else 0
                budget_change = read(f.pendingPOBudgetChange(pid))
                pos.append({'po_id':pid, 'ref':f'PO-{pid}', 'vendor_id':po[0], 'cap':money(po[1]),
                            'remaining':money(read(f.poRemaining(pid))), 'expiry':iso(po[4]),
                            'period_days':po[5], 'closed':po[8], 'started_at': iso(po[6]),
                            'current_period': period, 'spent_current_period': money(po[2] if period == po[7] else 0),
                            'total_paid': money(po[3]),
                            'pending_budget_change_id': Web3.to_hex(budget_change) if budget_change != ZERO else None})
            return {'vendors':vendors, 'pos':pos,
                    'pending_changes': pending, 'daily_cap': money(read(f.dailyLimit())),
                    'remaining_today': money(max(0, read(f.dailyLimit()) - read(f.spentToday()))),
                    'paused': read(f.paused()), 'vault_balance': money(self.w3.eth.get_balance(self.contract.address, block)),
                    'agents': [{'address': account, 'label': label, 'active': read(f.authorizedAgents(account)),
                                'balance': money(self.w3.eth.get_balance(account, block)), 'gas': 'self'}
                               for label, account in accounts.items()]}

    def owner_action(self, action):
        f, typ = self.contract.functions, action['type']
        owner = self.manifest['owner_address']
        if typ == 'pause': call = f.pause()
        elif typ == 'deactivateVendor': call = f.deactivateVendor(natural(action['vendorId']))
        elif typ == 'closePO': call = f.closePO(natural(action['poId']))
        elif typ == 'revokeAgent': call = f.revokeAgent(Web3.to_checksum_address(action['agent']))
        elif typ == 'lowerDailyCap': call = f.decreaseLimit(1, units(action['cap']))
        elif typ == 'lowerTotalBudget': call = f.decreaseLimit(0, units(action['cap']))
        elif typ == 'lowerPOBudget': call = f.decreasePOBudget(natural(action['poId']), units(action['cap']))
        elif typ == 'execute': call = f.execute(action['id'])
        elif typ == 'cancel': call = f.cancel(action['id'])
        elif typ == 'queue':
            kind, d = action['kind'], action.get('decoded', {})
            if kind == 'SetPayout': call = f.queuePayoutChange(natural(d['vendor_id']), Web3.to_checksum_address(d['new_payout']))
            elif kind == 'AddVendor': call = f.queueAddVendor(natural(d['vendor_id']), Web3.to_checksum_address(d['payout']))
            elif kind == 'AddPO':
                expiry = d['expiry']
                if not isinstance(expiry,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}',expiry):
                    raise ValueError('采购单到期日必须使用 YYYY-MM-DD')
                expires = int(datetime.fromisoformat(expiry+'T23:59:59+08:00').timestamp())
                call = f.queueAddPO(natural(d['po_id']),natural(d['vendor_id']),units(d['cap']),expires,natural(d.get('period_days',0),zero=True,maximum=2**32-1))
            elif kind == 'Withdraw': call = f.queueWithdraw(units(d['amount']))
            elif kind == 'Unpause': call = f.queueResume()
            elif kind in ('RaiseDailyCap', 'RaiseTotalBudget'):
                call = f.queueLimitIncrease(1 if kind == 'RaiseDailyCap' else 0, units(d['new_cap']))
            elif kind == 'RaisePOBudget':
                call = f.queuePOBudgetIncrease(natural(d['po_id']), units(d['new_cap']))
            elif kind == 'AddAgent': call = f.queueAgentAuthorization(Web3.to_checksum_address(d['agent']))
            else: raise ValueError('当前合约不支持此操作')
        else: raise ValueError('当前合约不支持此操作')
        tx, _ = self.send(call, owner)
        return {'hash': tx}

    def ledger(self, kind='all', limit=100):
        result, times = [], {}
        names = {'PayoutChangeQueued': 'ChangeQueued', 'ResumeQueued': 'ChangeQueued', 'LimitChangeQueued': 'ChangeQueued',
                 'AgentAuthorizationQueued': 'ChangeQueued', 'PayoutChangeExecuted': 'ChangeExecuted',
                 'ResumeExecuted': 'ChangeExecuted', 'LimitChangeExecuted': 'ChangeExecuted',
                 'AgentAuthorizationExecuted': 'ChangeExecuted', 'PayoutChangeCancelled': 'ChangeCancelled',
                 'ResumeCancelled': 'ChangeCancelled', 'LimitChangeCancelled': 'ChangeCancelled',
                 'AgentAuthorizationCancelled': 'ChangeCancelled', 'LimitChanged': 'DailyCapLowered',
                 'VendorQueued':'ChangeQueued', 'VendorAdded':'ChangeExecuted', 'VendorChangeCancelled':'ChangeCancelled',
                 'POQueued':'ChangeQueued', 'POAdded':'ChangeExecuted', 'POChangeCancelled':'ChangeCancelled',
                 'WithdrawalQueued':'ChangeQueued', 'WithdrawalExecuted':'ChangeExecuted', 'WithdrawalCancelled':'ChangeCancelled',
                 'POBudgetChangeQueued':'ChangeQueued', 'POBudgetChangeExecuted':'ChangeExecuted', 'POBudgetChangeCancelled':'ChangeCancelled'}
        events = self.events()
        # Prefer canonical PO events only when the matching legacy event is in the same transaction.
        canonical = {(bytes(log['transactionHash']), raw, args.get('changeId'))
                     for raw, args, log in events if raw.startswith('POBudgetChange') and args['poId'] == 101}
        changed = {(bytes(log['transactionHash']), args['oldCap'], args['newCap'])
                   for raw, args, log in events if raw == 'POBudgetChanged' and args['poId'] == 101}
        twins = {'LimitChangeQueued':'POBudgetChangeQueued', 'LimitChangeExecuted':'POBudgetChangeExecuted',
                 'LimitChangeCancelled':'POBudgetChangeCancelled'}
        for raw, args, log in reversed(events):
            tx_bytes = bytes(log['transactionHash'])
            if raw in twins and (tx_bytes, twins[raw], args.get('changeId')) in canonical: continue
            if raw == 'LimitChanged' and args['kind'] == 0 and (tx_bytes, args['oldLimit'], args['newLimit']) in changed: continue
            name = names.get(raw, raw)
            if kind == 'paid' and name != 'Paid': continue
            if kind == 'blocked' and name != 'Blocked': continue
            if kind == 'changes' and name in ('Paid', 'Blocked'): continue
            block = log['blockNumber']
            if block not in times: times[block] = iso(self.w3.eth.get_block(block)['timestamp'])
            tx = Web3.to_hex(log['transactionHash'])
            reason = args.get('reason', 0)
            if raw == 'Blocked' and reason == 0:
                raise ValueError('Blocked 不能使用 None 编码：接口不匹配')
            reasons = reason_fields(reason) if raw in ('Paid', 'Blocked') else {
                'reason_code': None, 'reason': None, 'reason_label_en': None, 'reason_label_zh': None}
            actor = args.get('agent')
            agent = next((k for k, v in self.manifest['agents'].items() if v.lower() == str(actor).lower()), None)
            summary = raw
            if raw == 'VendorDeactivated': summary = f'供应商 #{args["vendorId"]} 已停用'
            elif raw == 'POClosed': summary = f'采购单 PO-{args["poId"]} 已关闭'
            elif raw == 'WithdrawalExecuted': summary = '已向 Owner 提款 ' + money(args['amount']) + ' LOCAL'
            elif raw == 'VendorAdded': summary = f'供应商 #{args["vendorId"]} 已登记'
            elif raw == 'POAdded': summary = f'采购单 PO-{args["poId"]} 已登记'
            elif raw == 'POBudgetChangeQueued': summary = f'采购单 PO-{args["poId"]} 申请提额至 ' + money(args['newCap'])
            elif raw == 'POBudgetChanged': summary = f'采购单 PO-{args["poId"]} 预算：' + money(args['oldCap']) + ' → ' + money(args['newCap'])
            elif raw == 'POBudgetChangeExecuted': summary = f'采购单 PO-{args["poId"]} 提额已执行'
            elif raw == 'POBudgetChangeCancelled': summary = f'采购单 PO-{args["poId"]} 提额已取消'
            if raw == 'LimitChanged':
                # Do not mislabel a raise/total-budget update as a daily-cap reduction.
                name = 'LimitChanged'
                summary = ('总预算' if args['kind'] == 0 else '每日限额') + '：' + money(args['oldLimit']) + ' → ' + money(args['newLimit'])
            result.append({'id': f'{tx}:{log["logIndex"]}', 'name': name, 'tx_hash': tx,
                           'raw_name': raw, 'po_id': args.get('poId', 101 if raw == 'LimitChanged' and args['kind'] == 0 else None),
                           'change_id': Web3.to_hex(args['changeId']) if 'changeId' in args else None,
                           'explorer_url': '/api/local/tx/' + tx, 'block_time': times[block], 'agent': agent,
                           'vendor_id': args.get('vendorId'), 'vendor_name': '本地测试供应商' if args.get('vendorId') == 7 else f'供应商 #{args["vendorId"]}' if 'vendorId' in args else None,
                           'amount': money(args['amount']) if 'amount' in args else None,
                           'pay_to': args.get('payTo'), **reasons,
                           'summary_en': raw, 'summary_zh': summary, 'network': 'local'})
            if len(result) >= limit: break
        return result
