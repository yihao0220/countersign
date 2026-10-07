# CountersignDemo 本地接口 v1

确认与实现日期：2026-10-07。仅 Anvil、chain ID 31337、18 位小数的虚拟原生币；不是团队已批准的正式接口。

功能链：HTTP 白名单 → 当前 Demo 合约 → 实际交易回执 → 已保存的付款结果 / 账本。本文固定当前名称、字段和拒付定义，不改变已经确认的权限、120 秒等待或周期规则。

## 可交付接口文件

- [ABI JSON](../contracts/interface/CountersignDemo.abi.json)：函数、事件、错误、构造函数的完整机器接口。
- [拒付定义](../contracts/interface/block-reasons.json)：编码、英文名称、中英文展示文本的唯一共享定义。
- Solidity ABI 真相来自 contracts/out/CountersignDemo.sol/CountersignDemo.json。后端直接读取该构建产物；frontend/scripts/abi.mjs 从它生成交付 ABI 和前端常量，并从共享定义生成前端拒付常量。

重新生成前先在 contracts 执行 Forge build，然后在 frontend 执行 `node scripts/abi.mjs`。`node scripts/check-interface.mjs` 核对页面现有 15 种调用的名称、参数、金额单位与实际 ABI 编码，不发送交易。backend/tests/test_interface_alignment.py 检查 Solidity 枚举、共享定义和全部生成结果一致。

## 付款结果

`pay(vendorId, payTo, poId, amount, invoiceHash)` 由已授权 Agent 调用。amount 在合约中是整数 wei；HTTP amount/cap/new_cap 是十进制字符串，如 `"10.25"`，不能用浮点数表达精确金额。当前本地治理编号范围为 1 至 2^53−1；不是对 Solidity uint256 范围的修改。

- Paid：成功付款。HTTP event=Paid，reason_code=0，reason/展示原因=null。
- Blocked：已授权调用被规则拒付，交易本身仍成功；reason_code 为真实 1–13，reason 为固定英文名称。预算、付款累计、余额和防重标记不改变。
- 未授权、重入、实际转账失败：交易回滚，不伪造 Blocked；不能以回执 status=1 代替 Paid 判断。
- 同时违反多个规则时，保持现有 _check 的首个原因：暂停 → 供应商存在/有效 → 收款地址 → PO 存在/归属/关闭/到期 → 金额 → PO 预算 → 防重 → 实际余额 → 每日额度。

HTTP /api/attempts/{id} 的 tx 与 /api/ledger 使用相同 reason_code / reason / reason_label_en / reason_label_zh。未知编码报告“接口不匹配”，账本返回 HTTP 409；不会解释成其他已知原因。历史记录可能没有 reason_code，前端类型允许缺省；本轮新结果均包含该字段。

## 查询

GET /api/registry 在一个已确定区块读取状态和时间，避免跨周期查询混合新旧值。已有字段保留；pos 中每份采购单包含：

| 字段 | 意义 |
|---|---|
| po_id / vendor_id | 采购单及归属供应商编号 |
| cap / remaining | 本份额度 / 当前付款可用额度，十进制字符串；关闭或到期 remaining=0 |
| period_days | 0 为一次性；正数为从执行生效时刻起算的固定天数，不是自然月 |
| started_at / expiry | 周期起点 / 固定截止时间，UTC ISO 时间字符串 |
| current_period | 当前周期编号，从 0 开始；一次性恒为 0 |
| spent_current_period | 当前周期已付；周期已切换但尚无新付款时为 0 |
| total_paid | 该 PO 全部周期的累计已付；关闭、到期、调额、换周期都保留 |
| closed | 是否永久关闭 |
| pending_budget_change_id | 该 PO 的待执行提额编号，无则 null |

purchaseOrders 的链上 spent / period 是最后写入的周期账目；查询当前用量必须比较它与当前周期，不能直接把旧 spent 展示为本周期用量。totalBudget / remainingBudget / totalSpent / poExpiry 是 PO-101 的兼容查询，不代表全部 PO。totalPaid 才是全金库累计付款。金库余额独立于预算，周期恢复不增加资金。空模式这些 PO-101 查询在其创建前为零，创建时才设置预算与 poExpiry；PO-101 只允许一次性。agent() 在空模式始终为零，实际权限查 authorizedAgents。

## 本地治理 HTTP

POST /api/local/owner：仅当前本机测试服务使用的 Owner 快捷接口，不等于生产身份验证。

| type / kind | 参数 | 实际合约入口 |
|---|---|---|
| pause | — | pause |
| deactivateVendor | vendorId | deactivateVendor |
| closePO | poId | closePO |
| revokeAgent | agent | revokeAgent |
| lowerDailyCap | cap | decreaseLimit(1, cap) |
| lowerPOBudget | poId、cap | decreasePOBudget |
| lowerTotalBudget（兼容） | cap | decreaseLimit(0, cap)，仅 PO-101 |
| execute / cancel | id | execute / cancel |
| queue / AddVendor | decoded.vendor_id、payout | queueAddVendor |
| queue / SetPayout | decoded.vendor_id、new_payout | queuePayoutChange |
| queue / AddPO | decoded.po_id、vendor_id、cap、expiry、period_days | queueAddPO |
| queue / AddAgent | decoded.agent | queueAgentAuthorization |
| queue / RaiseDailyCap | decoded.new_cap | queueLimitIncrease(1, new_cap) |
| queue / RaisePOBudget | decoded.po_id、new_cap | queuePOBudgetIncrease |
| queue / RaiseTotalBudget（兼容） | decoded.new_cap | queueLimitIncrease(0, new_cap)，仅 PO-101 |
| queue / Unpause | — | queueResume |
| queue / Withdraw | decoded.amount | queueWithdraw，固定提款到 Owner |

AddPO 的 expiry 输入 YYYY-MM-DD，转换为中国时区该日 23:59:59；period_days 为 uint32，0 表示一次性。编号/周期不能用布尔值或小数；整数精度不够的编号不能发送。管理操作校验或执行失败返回 HTTP 409，模型输入类型失败返回 422。

示例提额：`{"type":"queue","kind":"RaisePOBudget","decoded":{"po_id":102,"new_cap":"120"}}`。示例降额：`{"type":"lowerPOBudget","poId":102,"cap":"60"}`。提额仍等待 120 秒且必须执行，降额仍立即生效并取消该 PO 旧提额；已付历史不清空。

pending_changes 固定返回 id、kind、decoded、eta、ready。任意 PO 提额统一为 RaisePOBudget，decoded 包含 po_id 和 new_cap；旧 PO-101 入口也返回这种形状。ready 只说明等待已结束，不保证在供应商、采购单或余额变化后执行一定成功。前端操作白名单已接入新预算请求，已有待执行列表可查看、执行、取消；本轮没有新增调额表单。

## 事件归类与去重

账本保留已有字段并新增 raw_name（实际事件名）、po_id、change_id；治理事件的 reason_code=null。排队/执行/取消统一显示 ChangeQueued / ChangeExecuted / ChangeCancelled，实际预算变化为 POBudgetChanged；每日额度变化仍为 LimitChanged。

PO-101 同时发出兼容 Limit* 与 POBudget*。待执行列表按 changeId 去重；账本只有在同一交易内找到匹配的新事件时才省略旧事件。排队/执行/取消还须匹配 changeId，预算改变还须匹配 PO-101 和旧/新额度。不同交易、不同申请、每日额度事件不合并。执行提额会显示“预算改变”和“申请已执行”两条不同语义，不能删成一条。

GET /api/local/tx/{hash} 保留回执所有实际日志，没有删除链上事件。接口拒付只说明规则不满足，不证明发票真实或已交付。

## 复跑与证据边界

项目根目录执行 `./test.sh interface-demo`：临时 Anvil + HTTP 接口 + 保存结果 + 账本，演示 PO-102 付款 30 后排队提至 120，提前执行拒绝、到期执行后剩 90且历史保留；另演示 12/POVendorMismatch、13/POClosed、11/VendorInactive 三种拒付一致且余额不变。HTTP 使用 TestClient 在进程内访问实际 FastAPI 路由，Anvil RPC 为实际临时节点；不启动页面或 HTTP 监听端口。时间在隔离实例模拟，不影响正在运行的链。

第六项新增 30 项接口测试，当轮后端完整 75 项通过；前端类型检查、构建及 15 种调用编码核对通过。Solidity 源码未改，本轮未重跑已有 166 项合约测试。页面布局和样式未改，也未重新做浏览器点击/真实钱包签名验收。第七项已完成空金库初始化，最新完整合约 181 项、后端 88 项及前端检查通过，详见 [初始化说明](INITIALIZATION.md)；五参数构造函数和已有函数/事件/getter 签名、拒付编号保持兼容。公链、真实资金、团队正式接入和安全审计没有新增证据。

## 固定拒付编码

| 编码 | 名称 | 含义 |
|---|---|---|
| 0 | None | 无 |
| 1 | UnknownVendor | 未知供应商 |
| 2 | PayoutMismatch | 收款地址不符 |
| 3 | UnknownPO | 采购单不存在 |
| 4 | InvalidAmount | 金额为零 |
| 5 | OverBudget | 超出预算 |
| 6 | DuplicateInvoice | 重复发票 |
| 7 | InsufficientFunds | 金库余额不足 |
| 8 | Paused | 已暂停 |
| 9 | POExpired | 采购单已过期 |
| 10 | DailyLimitExceeded | 超出每日限额 |
| 11 | VendorInactive | 供应商已停用 |
| 12 | POVendorMismatch | 采购单不属于该供应商 |
| 13 | POClosed | 采购单已关闭 |

## 完整函数和查询签名

下表从本轮实际 Demo ABI 核对。返回字段按 ABI 顺序；金额均为 wei，时间为 Unix 秒。`uint8` 的 LimitKind 为 TotalBudget=0 / DailyLimit=1，ChangeStatus 为 None=0 / Pending=1 / Executed=2 / Cancelled=3。没有参数或返回值用 — 表示。

| 函数（参数按顺序） | 属性 | 返回值（按顺序） |
|---|---|---|
| DELAY() | view | uint256 (unnamed) |
| PO_ID() | view | uint256 (unnamed) |
| VENDOR_ID() | view | uint256 (unnamed) |
| agent() | view | address (unnamed) |
| agentAuthorizations(bytes32 (unnamed)) | view | address account, uint256 executeAfter, uint8 status |
| authorizedAgents(address (unnamed)) | view | bool (unnamed) |
| cancel(bytes32 changeId) | nonpayable | — |
| closePO(uint256 poId) | nonpayable | — |
| dailyLimit() | view | uint256 (unnamed) |
| deactivateVendor(uint256 vendorId) | nonpayable | — |
| decreaseLimit(uint8 kind, uint256 newLimit) | nonpayable | — |
| decreasePOBudget(uint256 poId, uint256 newCap) | nonpayable | — |
| execute(bytes32 changeId) | nonpayable | — |
| limitChanges(bytes32 (unnamed)) | view | uint8 kind, uint256 newLimit, uint256 executeAfter, uint8 status |
| owner() | view | address (unnamed) |
| paidInvoices(bytes32 (unnamed)) | view | bool (unnamed) |
| pause() | nonpayable | — |
| paused() | view | bool (unnamed) |
| pay(uint256 vendorId, address payTo, uint256 poId, uint256 amount, bytes32 invoiceHash) | nonpayable | bool paid |
| payout() | view | address (unnamed) |
| payoutChangeVendor(bytes32 (unnamed)) | view | uint256 (unnamed) |
| payoutChanges(bytes32 (unnamed)) | view | address newPayout, uint256 executeAfter, uint8 status |
| pendingAgentAuthorization(address (unnamed)) | view | bytes32 (unnamed) |
| pendingLimitChange(uint8 (unnamed)) | view | bytes32 (unnamed) |
| pendingPOBudgetChange(uint256 poId) | view | bytes32 (unnamed) |
| pendingPOChange(uint256 (unnamed)) | view | bytes32 (unnamed) |
| pendingPayoutChange() | view | bytes32 (unnamed) |
| pendingResumeChange() | view | bytes32 (unnamed) |
| pendingVendorChange(uint256 (unnamed)) | view | bytes32 (unnamed) |
| pendingVendorPayoutChange(uint256 (unnamed)) | view | bytes32 (unnamed) |
| pendingWithdrawal() | view | bytes32 (unnamed) |
| poBudgetChanges(bytes32 (unnamed)) | view | uint256 poId, uint256 newCap, uint256 executeAfter, uint8 status |
| poChanges(bytes32 (unnamed)) | view | uint256 poId, uint256 vendorId, uint256 cap, uint64 expiry, uint32 periodDays, uint256 executeAfter, uint8 status |
| poCount() | view | uint256 (unnamed) |
| poExpiry() | view | uint64 (unnamed) |
| poIds(uint256 (unnamed)) | view | uint256 (unnamed) |
| poRemaining(uint256 poId) | view | uint256 (unnamed) |
| purchaseOrders(uint256 (unnamed)) | view | uint256 vendorId, uint256 cap, uint256 spent, uint256 totalPaid, uint64 expiry, uint32 periodDays, uint64 startedAt, uint256 period, bool closed, bool exists |
| queueAddPO(uint256 poId, uint256 vendorId, uint256 cap, uint64 expiry, uint32 periodDays) | nonpayable | bytes32 changeId |
| queueAddVendor(uint256 vendorId, address newPayout) | nonpayable | bytes32 changeId |
| queueAgentAuthorization(address account) | nonpayable | bytes32 changeId |
| queueLimitIncrease(uint8 kind, uint256 newLimit) | nonpayable | bytes32 changeId |
| queuePOBudgetIncrease(uint256 poId, uint256 newCap) | nonpayable | bytes32 changeId |
| queuePayoutChange(uint256 vendorId, address newPayout) | nonpayable | bytes32 changeId |
| queueResume() | nonpayable | bytes32 changeId |
| queueWithdraw(uint256 amount) | nonpayable | bytes32 changeId |
| remainingBudget() | view | uint256 (unnamed) |
| resumeChanges(bytes32 (unnamed)) | view | uint256 executeAfter, uint8 status |
| revokeAgent(address account) | nonpayable | — |
| spentByDay(uint256 (unnamed)) | view | uint256 (unnamed) |
| spentToday() | view | uint256 (unnamed) |
| totalBudget() | view | uint256 (unnamed) |
| totalPaid() | view | uint256 (unnamed) |
| totalSpent() | view | uint256 (unnamed) |
| vendorChanges(bytes32 (unnamed)) | view | uint256 vendorId, address payout, uint256 executeAfter, uint8 status |
| vendorCount() | view | uint256 (unnamed) |
| vendorIds(uint256 (unnamed)) | view | uint256 (unnamed) |
| vendors(uint256 (unnamed)) | view | address payout, bool exists, bool active |
| withdrawalChanges(bytes32 (unnamed)) | view | uint256 amount, uint256 executeAfter, uint8 status |

构造函数：`constructor(address agent_, address payout_, uint256 budget_, uint64 expiry_, uint256 dailyLimit_)`。Owner 固定为部署者。合法预置参数初始化供应商 7、PO-101 和首个 Agent，初始配置未经时间锁。五参数及部署资金全部为零时进入空模式：零登记、零授权、零预算/余额且暂停，所有初始配置走已有排队/等待/执行入口。其他参数组合沿用原校验。poExpiry getter 签名不变，空模式由 PO-101 创建时设置，创建后不能延期；不提供免等待的初始化接口。

## 完整事件字段

| 事件 | 字段（按顺序，indexed 表示日志 topic 字段） |
|---|---|
| AgentAuthorizationCancelled | bytes32 changeId indexed, address account indexed |
| AgentAuthorizationExecuted | bytes32 changeId indexed, address account indexed |
| AgentAuthorizationQueued | bytes32 changeId indexed, address account indexed, uint256 executeAfter |
| AgentRevoked | address account indexed |
| Blocked | uint8 reason, uint256 vendorId, address payTo, uint256 poId, uint256 amount, bytes32 invoiceHash, address agent |
| LimitChangeCancelled | bytes32 changeId indexed |
| LimitChangeExecuted | bytes32 changeId indexed |
| LimitChangeQueued | bytes32 changeId indexed, uint8 kind indexed, uint256 newLimit, uint256 executeAfter |
| LimitChanged | uint8 kind indexed, uint256 oldLimit, uint256 newLimit |
| POAdded | bytes32 changeId indexed, uint256 poId indexed, uint256 vendorId |
| POBudgetChangeCancelled | bytes32 changeId indexed, uint256 poId indexed |
| POBudgetChangeExecuted | bytes32 changeId indexed, uint256 poId indexed |
| POBudgetChangeQueued | bytes32 changeId indexed, uint256 poId indexed, uint256 newCap, uint256 executeAfter |
| POBudgetChanged | uint256 poId indexed, uint256 oldCap, uint256 newCap |
| POChangeCancelled | bytes32 changeId indexed, uint256 poId indexed |
| POClosed | uint256 poId indexed |
| POQueued | bytes32 changeId indexed, uint256 poId indexed, uint256 vendorId, uint256 cap, uint64 expiry, uint32 periodDays, uint256 executeAfter |
| Paid | uint256 vendorId indexed, uint256 poId indexed, address payTo, uint256 amount, bytes32 invoiceHash, address agent |
| Paused | address account indexed |
| PayoutChangeCancelled | bytes32 changeId indexed |
| PayoutChangeExecuted | bytes32 changeId indexed, address oldPayout, address newPayout |
| PayoutChangeQueued | bytes32 changeId indexed, uint256 vendorId indexed, address oldPayout, address newPayout, uint256 executeAfter |
| ResumeCancelled | bytes32 changeId indexed |
| ResumeExecuted | bytes32 changeId indexed |
| ResumeQueued | bytes32 changeId indexed, uint256 executeAfter |
| VendorAdded | bytes32 changeId indexed, uint256 vendorId indexed, address payout |
| VendorChangeCancelled | bytes32 changeId indexed, uint256 vendorId indexed |
| VendorDeactivated | uint256 vendorId indexed |
| VendorQueued | bytes32 changeId indexed, uint256 vendorId indexed, address payout, uint256 executeAfter |
| WithdrawalCancelled | bytes32 changeId indexed |
| WithdrawalExecuted | bytes32 changeId indexed, address payTo indexed, uint256 amount |
| WithdrawalQueued | bytes32 changeId indexed, uint256 amount, uint256 executeAfter |

完整自定义错误签名包含在交付 ABI JSON。治理交易失败可能是权限、状态、时间锁或参数错误；这些回滚不采用付款 BlockReason 编码。
