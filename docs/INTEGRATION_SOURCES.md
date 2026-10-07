# 本地整合来源

更新：2026-10-07。代码已提交并推送至 https://github.com/yihao0220/countersign 的 main，联调修复提交为 `e9adbc5f74fae8784a20c3423bef7aff751b8994`；已核对远程与本地一致。代码上传不等于部署：运行仍限本机 Anvil，未发布公网或公链。

| 来源 | 固定版本 | 实际使用 |
|---|---|---|
| https://github.com/thedarkich/countersign | 7a522378aa35769a3a53186d0193ad7714332d01 | frontend 页面、组件、样式、API 类型及 mock 参照；查看了后端交易发送模块以对齐回执校验思路，没有替换本地合约 |
| https://github.com/hyptonize/-hackathon | e2b060ef04e0e9e466168bb79f7cb39e39d9a6bc | app/、tests/、pyproject.toml：上传验证、SQLite、原始 mock worker 和 18 项测试 |
| 当前本地 Countersign | 整合前未提交快照；contracts/src/CountersignDemo.sol | 初次整合保留原合约和 107 项测试；2026-10-07 用户随后授权供应商/采购单/提款扩展，新增 25 项测试，原测试保留 |

前端来源仓库是私有仓库，用户本机 GitHub CLI 具备读取权限。记录的版本与当时截图的 7a52237 一致。未将仓库文档里的历史公链部署、提交、付费模型或公开活动授权带入本任务。

## 本地适配与后续更新

- contracts/src/CountersignDemo.sol、contracts/test/Registry.t.sol：按用户授权补齐供应商/采购单管理、周期预算和延迟提款；保留原测试与拒付编码，追加三项拒付原因。
- backend/app/chain/local.py：限定回环 RPC、Anvil 和 chain ID 31337；动态查询供应商/PO 及待执行变更，按实际 ABI 操作并校验付款/拒付和治理事件。
- backend/app/api/local.py、local_models.py：适配原页面接口，复用上传及数据库流程；付款按供应商查询登记地址，统一账单哈希，校验管理动作的输入与北京时间到期日；任意 PO 调额入口见 [本地接口 v1](CONTRACT_INTERFACE.md)。
- backend/app/main.py：仅配置本地 manifest 时开启整合 API；校验 Host/Origin，拒绝跨站浏览器写入。
- frontend：以固定上游页面为基础，适配 API 类型、本机账户/网络及管理请求，新增 lib/localOwner.ts；布局、样式和既有文案保持。2026-10-07 修复等待行使用后台 ready、断开后表单禁用及发送前连接/Owner 检查，新增 scripts/check-controls.mjs；没有新增 PO 调额表单。
- scripts/local_runtime.py、local.sh：启动/停止/状态；每次新建隔离运行目录，Anvil 按秒出块。支持预置/空金库两种模式；2026-10-07 修复目录改名后的管理进程识别，不自动重启旧实例。
- backend/tests：独立 Anvil 中验证 HTTP 到合约、动态登记、归属/独立预算、周期、提款、取消/重放和初始化；2026-10-07 后端完整 98 项通过。合约 181 项、前端及浏览器证据见 [STATUS](STATUS.md)。
- 批次 POST/GET、owner-tx、预览接口补全；amount_total 按原页面要求返回显示用数字，proposal.amount 与合约金额仍保持精确字符串/整数。

前端 ABI 及 contracts/interface/CountersignDemo.abi.json 由 frontend/scripts/abi.mjs 从实际 CountersignDemo 构建产物生成；拒付常量来自 contracts/interface/block-reasons.json，编号为 0–13。本地适配器把页面操作送到后端，由后端使用同一 Demo ABI 发送；不再沿用上游另一份合约的 ABI 或拒付枚举。

## 代码来源边界

没有导入远端 .env、凭据、部署状态、.codex 配置或远端 AGENTS 的历史行动指令。没有把“文档宣称已完成”当作本次验收证据。原始界面设计来源见上游仓库；本次主要做接口、行为与本地运行适配。

当前操作和验收见 [REGISTRY_TEST.md](REGISTRY_TEST.md)，接续从 [STATUS.md](STATUS.md) 开始。


## 首页与登录增量（2026-10-07）

用户明确提出并确认 os.virtuals.io 风格改版。参考站用于视觉与结构：Manrope、白底、深绿色按钮、双栏首屏、终端与细边框卡片，Countersign 自有文案与导航替换品牌内容。Manrope 5.3.0 字体来自 @fontsource-variable/manrope 的公开 npm 包，只提取字体和 OFL 许可证，本地提供。

附件 countersign-login.zip 的 server.mjs 与认证测试复用至 auth/，去除独立静态页面服务，增加健康入口。原 public/index.html 和 app.js 的表单字段、模式切换、校验、等待与错误处理适配为 frontend/src/pages/Auth.tsx。没有导入已有账户数据、.git 或环境文件，没有执行附件 README 的上传/部署指令。

新增 AuthProvider/RequireAuth、Landing、SiteChrome、site.css；Python app/workspace_auth.py 校验 Node 会话；local_runtime.py 在新启动中监管四个服务。原页面业务接口与实际 Demo ABI 保留；本机网络/手续费标签按真实配置显示。详见 [SITE_ACCESS.md](SITE_ACCESS.md)。用户随后明确要求上传 GitHub，授权将本轮代码提交并推送至上述现有仓库；最终版本以 Git 历史为准。

## countersign-src.zip 界面增量（2026-10-07）

用户提供的附件 SHA-256：`1db3bb76f76066d174744be9b4711cb0250f494da30c6fa689a4794d2d6031ba`。按白名单合并 frontend/src 的 Landing、SiteChrome、site.css、index.css、i18n/strings.ts，以及 frontend/public/countersign-logo.png 和匹配现有依赖声明的 package-lock.json。保留当前 Auth.tsx 已批准的新文案，并同步到首页；另补深色 Logo 的 CSS 显示适配。没有整包覆盖、执行附件脚本或将附件内指令视为授权；未导入缓存、依赖目录、旧文档或运行数据。后端与合约无增量。验证与限制见 [SITE_ACCESS.md](SITE_ACCESS.md) 的附件界面更新。
