# 本地整合来源

更新：2026-10-07。代码仅整合到现有独立本地仓库，未提交、推送、连接项目远程或部署公网。

| 来源 | 固定版本 | 实际使用 |
|---|---|---|
| https://github.com/thedarkich/countersign | 7a522378aa35769a3a53186d0193ad7714332d01 | frontend 页面、组件、样式、API 类型及 mock 参照；查看了后端交易发送模块以对齐回执校验思路，没有替换本地合约 |
| https://github.com/hyptonize/-hackathon | e2b060ef04e0e9e466168bb79f7cb39e39d9a6bc | app/、tests/、pyproject.toml：上传验证、SQLite、原始 mock worker 和 18 项测试 |
| 当前本地 Countersign | 整合前未提交快照；contracts/src/CountersignDemo.sol | 初次整合保留原合约和 107 项测试；2026-10-07 用户随后授权供应商/采购单/提款扩展，新增 25 项测试，原测试保留 |

前端来源仓库是私有仓库，用户本机 GitHub CLI 具备读取权限。记录的版本与当时截图的 7a52237 一致。未将仓库文档里的历史公链部署、提交、付费模型或公开活动授权带入本任务。

## 本次新增与改动

- contracts/src/CountersignDemo.sol、contracts/test/Registry.t.sol：按用户授权补齐供应商/采购单管理、周期预算和延迟提款；保留原测试与拒付编码，追加三项拒付原因。
- backend/app/chain/local.py：限定回环 RPC、Anvil 和 chain ID 31337；动态查询供应商/PO 及待执行变更，按实际 ABI 操作并校验付款/拒付和治理事件。
- backend/app/api/local.py、local_models.py：适配原页面接口，复用上传及数据库流程；付款按供应商查询登记地址，统一账单哈希，校验五项管理动作的输入与北京时间到期日。
- backend/app/main.py：仅配置本地 manifest 时开启整合 API；校验 Host/Origin，拒绝跨站浏览器写入。
- frontend：先将导入的 44 个文件恢复到固定上游版本。随后仅修改 API 类型、wagmi 本机账户/网络配置、Controls 的请求适配、Ledger 两处网络类型声明，新增 lib/localOwner.ts，并扩展五项操作白名单；页面 JSX、样式和既有文案保持原样。
- scripts/local_runtime.py、local.sh：启动/停止/状态；每次新建隔离运行目录，Anvil 按秒出块以驱动真实时间锁倒计时。
- backend/tests/test_local_integration.py：独立 Anvil 中的 HTTP 到合约回归，覆盖原接口联调，以及动态登记、归属/独立预算、周期、固定提款地址、取消/重放和无效输入；后端全套 45 项通过。
- 批次 POST/GET、owner-tx、预览接口补全；amount_total 按原页面要求返回显示用数字，proposal.amount 与合约金额仍保持精确字符串/整数。

前端原有 ABI 文件保持上游原样，本地控制调用不会使用它；本地适配器把原页面操作送到后端，由后端使用 CountersignDemo 的实际 ABI 发送。拒付原因解码以本地合约枚举为准。

## 代码来源边界

没有导入远端 .env、凭据、部署状态、.codex 配置或远端 AGENTS 的历史行动指令。没有把“文档宣称已完成”当作本次验收证据。原始界面设计来源见上游仓库；本次主要做接口、行为与本地运行适配。

当前操作和验收见 [REGISTRY_TEST.md](REGISTRY_TEST.md)，接续从 [STATUS.md](STATUS.md) 开始。
