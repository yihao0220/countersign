# 队友下载后，在自己的电脑测试

这份仓库包含首页、注册登录、后端、数据库建表和本地智能合约。安装依赖后，每台电脑可以独立启动、自己注册账户、测试付款与管理操作。不需要项目作者提供账号，也不需要钱包私钥、模型密钥或真实资金。尚未接入真实 AI/OCR，发票样例使用标注的测试规则，PDF/图片上传需人工核对。

每个人的 `127.0.0.1:5173` 都指向自己的电脑，链、余额、账户和账本也各自独立。你不能用作者本机注册的账户登录自己刚启动的实例。共享账号只能用于同一个已部署的网址；目前没有供不同地点访问的统一服务器。

## 准备环境

- Mac/Linux：使用终端。Windows：在 WSL2/Ubuntu 内完成以下安装和运行，不能直接把 Bash 命令粘到 PowerShell；本轮没有 Windows 实机验收。
- 安装 Git、Python 3.12、Node.js 22 或以上、pnpm，以及 Forge/Anvil。Foundry 安装以 [官方指南](https://getfoundry.sh/getting-started/installation) 为准，本项目验证使用 Foundry 1.7.1。
- Python、Node、Foundry 必须安装在运行这些命令的同一个环境中；Windows 安装的程序不等于 WSL 内已安装。

先确认以下命令都能显示版本：

```bash
git --version
python3 --version
node --version
pnpm --version
forge --version
anvil --version
```

## 下载和安装

以下命令在 Mac/Linux 终端或 Windows 的 WSL 终端中执行。首次安装需要联网下载依赖与 Solidity 编译器。

```bash
git clone https://github.com/yihao0220/countersign.git
cd countersign

python3 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements-local.lock
.venv/bin/python -m pip install --no-deps -e ./backend
.venv/bin/python -m pip check

mkdir -p .tools
cp "$(command -v forge)" .tools/forge
cp "$(command -v anvil)" .tools/anvil
.tools/forge install --root contracts --no-git --shallow foundry-rs/forge-std@v1.9.7
.tools/forge build --root contracts

cd frontend
pnpm install --frozen-lockfile --ignore-scripts
pnpm run build
cd ..

./local.sh start
./local.sh status
```

也可以在 GitHub 下载 ZIP、解压并进入 `countersign-main` 目录，省略 `git clone`，再从 `python3 -m venv .venv` 开始。解压工具若没有保留脚本执行权限，先运行 `chmod +x local.sh test.sh`。不要复制作者的 `.venv`、`.tools` 或 `node_modules`：它们可能不适配你的系统。

## 注册并测试

1. 打开 `http://127.0.0.1:5173/`，点击「创建账户」。自行填写姓名、邮箱及至少 10 个字符的密码，然后进入工作台。这个本地版本没有邮箱验证，不向该邮箱发送邮件。
2. 在收件箱选择「带防护」，运行一次「正常付款」：应付款 100，初始余额 500 变为 400。再次运行相同账单应拒绝重复付款。两个 Agent 共用同一账单防重记录。
3. 进入控制台，点击连接，并选择「本机测试账户（无真实签名）」。这是本次 Anvil 合约的 Owner 测试身份，和刚注册的工作台账户是两层检查，不需要额外管理员邮箱或密码。
4. 测试新增供应商时，填入未使用的编号及完整的 `0x` 加 40 位十六进制地址；可以从 Agent 卡片复制本机已有测试地址。提交后应出现在待执行列表，完整等待 120 秒，再点「执行」。排队成功并不等于供应商已生效；有供应商后还要配置采购单才能付款。
5. 账本应显示付款、拒付及管理事件。其余采购单、暂停恢复、提款等步骤见 [控制台功能指南](REGISTRY_TEST.md)。

关闭使用 `./local.sh stop`。停止后再次启动会创建新链，余额回到 500、账本重新开始；自己注册的账户保留，但认证服务重启后要重新登录。新电脑首次启动使用默认预置演示；`start-empty` 的初始化差异见 [本地测试指南](LOCAL_TEST.md)。

## 常见问题

- `Access rejected`：先确认地址就是 `http://127.0.0.1:5173`，并已在本次实例注册/登录；不要改用另一端口访问旧后台。
- 能登录但管理按钮不可用：连接「本机测试账户（无真实签名）」，再检查是否处于等待期。注册账号不会替代链上 Owner 的连接检查。
- 提示端口被占用：5173、8000、3000、8545 必须可用；脚本不会擅自关闭其他进程。
- `forge` 或 `.tools/anvil` 找不到：确认官方 Foundry 已安装，并已执行上面的两条复制命令。不要使用另一种系统的二进制文件。
- 依赖下载失败：检查网络与安装工具的报错；共享测试账号无法修复依赖或网络问题。
- 登录数据位于 Git 忽略的 `.runtime/accounts`；数据库由后端自动建立在本次运行目录。不上传账号、密码、会话或数据库。

这里的管理身份仅用于本机虚拟资金测试，没有生产用户角色或账户到真实钱包的绑定。测试通过不等于真实 AI、远程部署、公链或生产资金验收。

## 本轮验收证据（2026-10-07）

从 Git 已追踪文件和待提交改动导出干净源码目录，未带入作者的账户、数据库、Python 环境或前端依赖。新建 Python 3.12 环境并按锁文件安装、`pip check` 通过；重新按 pnpm 锁文件安装 532 个包、页面构建和两项接口/控制台检查通过。发现并修复了 pnpm 锁文件遗漏三项已声明依赖的问题。独立获取 forge-std v1.9.7，合约编译通过；Forge/Anvil 使用本机已验证的官方工具副本，不是新电脑安装 Foundry 的实测。

干净目录运行初始化、工作台会话和本地合约接口测试 58 项通过；Node 注册/登录测试 6 项通过，覆盖新账户注册、登录、退出及账户重启保留。付款、供应商登记与时间锁使用独立临时 Anvil，不影响作者正在使用的链。主目录后台完整回归 106 项通过。

这些证据支持 macOS 上按所列依赖安装后的源码可运行，以及新账户能使用本地测试接口；不代表已在队友的电脑、Windows/WSL2或五台远程电脑实测，也不代表已经公开部署。本轮上传状态以 GitHub 提交记录为准。
