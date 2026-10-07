# Countersign 项目约定

## 接续与范围

- 2026-10-07 最新范围：用户明确要求并确认首页 → 附件的登录/注册 → 现有工作台，三段统一采用 os.virtuals.io 视觉。此次改版覆盖下方旧的“界面原样”限制；详见 docs/SITE_ACCESS.md。复用 auth/server.mjs，在新版 local.sh 启动时配置后台会话检查，账户不等于生产 Owner 角色。用户随后明确授权提交并推送本轮代码；仍不自动重启旧链、不部署公网。

- 先读 `docs/STATUS.md`，再按当前任务读 README 和相关源码，不默认从历史选题继续。
- 当前为第一版本地整合：入口 `./local.sh`，详情 `docs/LOCAL_TEST.md`。只有 Anvil 31337 和回环服务；不自动转公链或公网。
- 2026-10-07 用户明确：只连接前后端、补本次联调缺失接口；页面布局与既有文案保持原样，允许改接口和本地网络配置。不要继续前端改版。随后用户明确授权补供应商新增/停用、采购单新增/关闭、提款并回复“继续”；以此新范围为准。
- 合约仍用 CountersignDemo；前端本地适配经 backend/app/api/local.py / chain/local.py 调用实际 Demo ABI，不能发送上游另一个合约的 ABI 或套用其拒付枚举。
- 本地控制使用 Anvil 无价值解锁账户；不保存私钥。AI 测试规则必须标注，不把文件上传等同于识别完成。
- 集成验证 `.venv/bin/python -m pytest -q backend/tests`；前端 `pnpm run typecheck`、`pnpm run check:interface`、`pnpm run check:controls`、`pnpm run build`。运行状态、依赖、上传与数据库留在忽略目录。
- 本项目是本地教学与开发起点，核心源码为 `contracts/src/CountersignDemo.sol`；不等同于团队完整比赛金库。
- 用户负责智能合约，交流一次只讲一个概念或推进一个小任务；不要把听懂、亲自运行和独立实现混为一谈。
- 2026-10-06 六个演示均已有用户运行通过记录；已完成 `docs/PDF_ALIGNMENT.md`。2026-10-07 已授权并完成供应商/采购单/提款扩展，当前见 docs/REGISTRY_TEST.md。

## 修改与验证

- 修改核心代码前重读实际源码，先讲清行为、影响及验收，按已确认范围实施。
- Solidity 固定 0.8.30；现阶段保留 chain ID 31337 限制，仅用本地虚拟资金。
- 保留现有 `Paid` / `Blocked` 语义；已授权的规则拒付需留事件，未授权调用回滚。
- 管理员提交变更，任何地址只可执行已排队且到期的确定内容；取消和已执行记录不得重放。
- 修改合约后运行相应测试；文档收尾不重复跑完整合约测试。保持 README 与阶段状态一致。
- 前四个演示分别使用 `./test.sh demo`、`./test.sh timelock-demo`、`./test.sh pause-demo`、`./test.sh expiry-demo`；新增额度演示为 `./test.sh limits-demo`；Agent 演示为 `./test.sh agents-demo`；完整测试为 `./test.sh`。
- 构造函数五个参数为 Agent、初始收款地址、总预算、`uint64` 截止时间和每日上限。五参数及部署资金全零选择空模式，零登记/零授权/零预算且暂停；保留原合法预置模式。到期边界是当前区块时间大于或等于截止时间，日期固定且不能延期。
- 当前没有真实链或完整安全审计证据，不能把本地通过表述为上线验收。

## Git 与保存

- 本目录为独立仓库，不向母工作区仓库暂存项目正文。
- “保存代码”表示落盘和记录接续状态，不自动暂存、提交或推送。
- `.tools/`、`contracts/lib/`、构建缓存、生成物和凭据保持在忽略范围。

## 额度规则

- UTC 零点换日；全部 PO 的成功付款共享每日用量，每个 PO 分别扣预算；提款不占用每日或付款累计。
- decreaseLimit / queueLimitIncrease 的 TotalBudget 仅针对初始 PO-101，不能解释成全部 PO 的总预算；DailyLimit 针对全金库。PO-101 总预算减其累计已付等于 remainingBudget。
- Owner 可立即降额；PO-101 总预算不得低于该 PO 累计已付。提额等待 120 秒，执行和取消复用已有入口。降额取消同类待执行提额，每类最多一项，不清空历史或延期。
- 任意 PO 的预算入口为 decreasePOBudget / queuePOBudgetIncrease；一次性不得低于累计已付，周期不得低于本周期已付。每份 PO 最多一项提额，关闭或降额取消旧申请。PO-101 新旧入口共用 limitChanges / pendingLimitChange(TotalBudget)，其他 PO 使用 poBudgetChanges；统一查询 pendingPOBudgetChange(poId)。调额不重置账目或周期，已关闭 PO 禁止调额。第六项已接入本地接口和前端操作白名单；没有新增调额表单。

## 本地接口 v1（2026-10-07）

- 用户已确认第六项设计。函数/事件/查询见 docs/CONTRACT_INTERFACE.md；ABI 从实际 Demo 构建产物生成，不再使用上游 Countersign ABI。contracts/interface/block-reasons.json 是中英文拒付定义共享来源，枚举 0–13 保持不变。
- lowerPOBudget / queue-RaisePOBudget 支持任意 PO，pending 统一包含 po_id。PO-101 新旧事件在列表/账本合并，原始回执完整保留。
- registry 的周期和历史字段按同一区块读取。reason_code：Paid=0，Blocked=1–13，治理=null；未知编码显式报接口不匹配。
- 等待按钮以后台链上 ready 为准，并随查询更新；本机倒计时仅显示，不能授予执行权限。发送前读取当前连接和网络；execute 保留公共执行，其他管理操作需 Owner。子表单断开后不得继续提交；这些页面约束不等于生产后端认证。
- ./test.sh interface-demo 是隔离 Anvil 的 HTTP 演示。前端 node scripts/abi.mjs 生成 ABI/拒付常量；node scripts/check-interface.mjs 验证现有页面映射。新增/改接口后运行后端测试和前端检查，不把这些证据当作浏览器点击、钱包签名或公链验收。

## Agent 权限

- 预置模式初始 Agent 创建时授权；空模式没有初始 Agent。新增或重新授权由 Owner 排队等待 120 秒，复用 execute/cancel。
- Owner 立即撤销；同时取消该地址未执行授权，旧记录不可重放。每个地址最多一项 pending，不同地址互不覆盖。
- 零地址、Owner 地址和已授权地址不能申请授权；Owner 固定且不得成为 Agent。
- `agent()` 只表示初始地址，空模式始终为零；实际权限查 `authorizedAgents(account)`。
- 多个 Agent 共用金库、每日用量和重复标识记录，同一 PO 的预算也由所有 Agent 共用；权限变更不清空账目、不延期、不恢复暂停。
- 未授权付款回滚且不产生 Blocked；仅已授权的规则拒付记录 Blocked。

## 原方案对齐

- 新增功能前按 `docs/PDF_ALIGNMENT.md` 标明 PDF 要求、实现简化和用户确认调整，不能把核心方向符合说成原方案完整实现。
- 预置模式初始规则由构造函数设置，不属于时间锁；空模式完整初始化全部走登记时间锁，两种证据须分别说明。
- 供应商登记/active、多采购单及供应商归属、周期预算已补齐；ERC-20、Owner 交接及公链交付仍缺。原 PDF 的 Contracts 角色也包括 tx writer。
- 立即撤销 Agent、初始 PO-101 预算调额、延迟恢复和部分 ABI 名称与 PDF 有差异；用户已确认行为，团队接入仍需对齐。

## 供应商、采购单与提款（2026-10-07）

- queueAddVendor/queueAddPO/queueWithdraw 等待 120 秒，execute/cancel 共用入口；登记 ID 不能覆盖或重用。
- deactivateVendor 永久停用并取消该供应商待执行改地址；closePO 永久关闭，付款历史保留。新 PO 执行时重新检查供应商与 expiry。
- periodDays=0 为一次性；正数周期从 PO 执行时刻起算，未用额度不累加。跨周期不清空全局防重、每日用量或关闭/到期状态。
- totalBudget/remainingBudget/totalSpent/poExpiry 是 PO-101 的兼容查询；totalPaid 汇总所有 PO，提款不计入付款或每日用量。
- Withdrawal 固定到 immutable Owner，执行前再查余额，失败整体回滚；pause 只阻止 Agent 付款，不阻止管理/提款。
- 原拒付枚举 0–10 不变，末尾追加 VendorInactive/POVendorMismatch/POClosed。

## 空金库初始化（2026-10-07）

- 用户已回复“继续”确认第七项设计，实施见 docs/INITIALIZATION.md。默认 local.sh start 保留预置；start-empty 真空部署，两轮时间锁后核对状态才启动服务。
- 同模式复用，另一模式运行时拒绝切换，不自动停止/重启用户链；初始化失败不写 ready，停止本次子进程，不启动页面。新启动不是升级或迁移。
- 管理进程按 Python 脚本角色、serve 与完整运行编号识别；父目录改名不要求旧启动路径等于新绝对路径，不以任意命令子串判断。修改代码或上传 GitHub 不自动重启已有链。
- PO-101 只允许一次性，周期预算使用其他 ID；空模式创建前其兼容字段为零，创建时才设置。poExpiry 为存储字段，但仅创建时赋值，不可延期或复用编号。
- 本机 Anvil 初始时钟偏移与模拟等待匹配（demo 120 / empty 240 秒），后续新申请完整等待 120 秒。只允许 http://127.0.0.1 的 Anvil 31337，不保存/输出私钥。
- init-demo 为合约验收；init-script-demo 为独立 Anvil 的真实部署/回执与进程内 HTTP 验收，不能冒充完整页面、钱包签名、公链或审计证据。
