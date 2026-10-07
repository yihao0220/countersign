# 第六项：本地合约接口统一设计（用户已确认并实现）

日期：2026-10-07。用户回复“ok”确认后实施，交付与验证见 ../../CONTRACT_INTERFACE.md。范围为 CountersignDemo 与当前本地 Python/前端适配，不代表团队已批准正式比赛接口。

## 当前功能链与断点

页面提交 → 本地 HTTP 白名单 → Anvil 31337 的 CountersignDemo → 回执解码 → 页面与账本。

源码核对发现：

- backend/app/chain/local.py 使用实际 Demo ABI，但未接入任意 PO 的 decreasePOBudget / queuePOBudgetIncrease，也未识别 POBudgetChangeQueued。
- frontend/scripts/abi.mjs 仍读取另一份 Countersign.sol 的构建产物；Controls.tsx 的钱包分支使用 queueSetPayout、queueAddAgent、queueRaiseDailyCap、queueUnpause、lowerDailyCap 等旧名称。当前本地分支走 HTTP，因而既有本地操作仍可运行。
- frontend/src/lib/reasons.ts 的拒付顺序与 Demo 的 BlockReason 不同，缺少 InvalidAmount、DailyLimitExceeded、POClosed 的统一定义；后端另维护一份列表。
- registry 返回额度与剩余，未区分本周期已付和累计已付。purchaseOrders.spent / period 是最后写入的账目，跨周期后不能直接当作当前周期用量。
- PO-101 为兼容同时发出 Limit* 和 POBudget* 事件，直接展示全部事件会重复；其他 PO 的预算事件未归入统一治理事件。

## 方案选择

采用现有 Demo 接口作为本地 v1 约定，补齐适配和接口说明，不改变 Solidity 付款、权限、周期或时间锁行为。

替代方案一：只写接口文档。改动少，但任意 PO 调额仍不能经过当前 HTTP/前端适配，实际断点保留。

替代方案二：将合约改成上游旧 ABI 的函数名和编号。会影响已经验收的调用和历史回执，需要迁移；本轮不采用。

## 固定接口

以 contracts/out/CountersignDemo.sol/CountersignDemo.json 的 ABI 为构建真相；修正前端生成脚本和相应调用映射。生成结果与当前产物一致，检测再次生成无差异。保留现有 Solidity 名称、入参顺序、查询字段顺序、事件和错误；给出完整可查询的接口说明。只验证本地链。

付款固定为 pay(vendorId, payTo, poId, amount, invoiceHash)。Paid 表示成功付款，Blocked 表示已授权 Agent 的规则拒付；未授权调用回滚，不制造 Blocked。多个规则同时不满足时返回现有 _check 的首个原因，不调整优先级。

BlockReason 数值 0–13 固定：None、UnknownVendor、PayoutMismatch、UnknownPO、InvalidAmount、OverBudget、DuplicateInvoice、InsufficientFunds、Paused、POExpired、DailyLimitExceeded、VendorInactive、POVendorMismatch、POClosed。将数值、名称、展示文本集中到一份可读取的定义，后端与前端使用同一份定义；测试核对 Solidity 枚举，防止漂移。更新 mock 中旧原因名称。保留页面布局与既有显示文本；仅补新增原因文本。

HTTP 付款结果与账本新增 reason_code：Paid 为 0，Blocked 为真实编码；治理事件为 null。reason 保留现有英文名称或 null。未知编码明确报接口不匹配，不映射为其他已知原因。

## 查询与治理适配

registry 的 PO 保留已有字段，增加 current_period、spent_current_period、total_paid、started_at、pending_budget_change_id。一次性 PO 的 current_period 为 0；周期从 startedAt 起按 periodDays 算。只有存储 period 与当前周期相同时使用存储 spent，否则当前周期已付为 0；total_paid 始终使用历史累计。读取使用同一已确定区块的状态与时间，避免周期边界字段互相矛盾。closed/expiry 的 remaining 仍使用 poRemaining，不把 0 当作历史已付清零。

本地 Owner 白名单新增：

- lowerPOBudget：poId、cap → decreasePOBudget(poId, cap)，立即降额。
- queue / RaisePOBudget：decoded.po_id、decoded.new_cap → queuePOBudgetIncrease，等待 120 秒。

旧 lowerTotalBudget / RaiseTotalBudget 继续兼容，仅作用于 PO-101；待执行查询统一返回 RaisePOBudget 与 decoded.po_id / new_cap。每日额度继续为 RaiseDailyCap。前端补类型、说明及操作白名单，不新增调额表单或改页面布局。任意 PO 调额本轮可通过本地接口提交，并在已有待执行区域查看、执行、取消。

通过事件确定变更类型，读取相应 pending 状态。PO-101 新旧事件按同一 changeId 归并；旧记录从 limitChanges 读取，其他 PO 从 poBudgetChanges 读取。关闭/降额取消后的申请不显示为待执行。

账本新增 po_id、change_id、raw_name，归类 POBudget 的排队/执行/取消和预算改变。PO-101 同一交易内的新旧语义重复事件只展示一条；不同交易、不同 changeId 不能合并。保留原始回执中的所有真实日志，不修改或删去链上历史。每日调额不能被当作 PO 调额。

## 验收

1. HTTP 给 PO-102 排队提至 120：待执行查询包含正确 PO 和目标额度；提前执行拒绝；等待后执行，历史支出不变。降额、取消和关闭仍按原规则处理。
2. PO-101 新旧调额入口均只产生一条待执行展示；队列、执行、取消和额度改变的对应账本语义不重复。
3. 供应商停用返回 11 / VendorInactive，串用 PO 返回 12 / POVendorMismatch，关闭返回 13 / POClosed；回执、数据库查询和账本一致，拒付时账目不变。检验全部编号定义与 Solidity 一致。
4. 周期边界前后查询当前用量正确，累计已付不归零；无需新付款才显示新周期，金库余额不增加。一次性和关闭/到期字段也有边界验证。
5. ABI 生成与实际 Demo 一致；前端调用名称/参数匹配；前端类型检查与构建通过，后端完整测试通过。

只对改动范围运行必要回归。若 Solidity 未改，用源码哈希确认，不把已有合约测试结果冒充本轮新增结果。新增接口演示入口提供可复跑的真实 HTTP→本地 Anvil 场景。测试使用隔离实例，不重置用户正在运行的链。

## 影响与边界

新增查询字段兼容旧读取；待执行预算类型和 ABI/拒付定义需前后端一起更新，旧页面缓存需要刷新。新增操作沿用既有 Owner 和时间锁约束；不扩大 Agent 权限。

更新本轮接口文档、README、STATUS、相关项目约定；纠正 STATUS 已核实的主路径“黑客松/countersign”。不进行其他路径迁移或无关重构。

本轮不做从空构造初始化的第七项，不改提款规则、Owner 交接、ERC-20、生产发送队列或公链部署。未取得团队正式接口确认，也不新增真实钱包签名、真实资金或正式安全审计证据。代码只落盘，不暂存、提交或推送。
