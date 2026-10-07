#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "init-script-demo" ]]; then
  echo '空金库脚本演示：实际部署、时间锁初始化与 HTTP 付款；独立 Anvil，不启动或重置当前页面。'
  cd "$project_dir"
  if [[ ! -x .venv/bin/python || ! -x .tools/anvil || ! -x .tools/forge ]]; then
    echo '需要本地 Python、Forge 和 Anvil；安装说明见 docs/LOCAL_TEST.md。' >&2
    exit 1
  fi
  .tools/forge build --root contracts
  exec .venv/bin/python -m pytest -q -s backend/tests/test_initialization.py -k 'demo_empty_script_then_http_two_vendor_payment'
fi
if [[ "${1:-}" == "interface-demo" ]]; then
  echo '本地接口演示：HTTP 接口调额；回执/保存结果/账本统一拒付编码；临时 Anvil 与当前运行的链隔离。'
  cd "$project_dir"
  if [[ ! -x .venv/bin/python || ! -x .tools/anvil || ! -f contracts/out/CountersignDemo.sol/CountersignDemo.json ]]; then
    echo '需要已安装的本地测试依赖和 Demo 构建产物；初始化说明见 docs/LOCAL_TEST.md。' >&2
    exit 1
  fi
  exec .venv/bin/python -m pytest -q -s backend/tests/test_interface_alignment.py -k 'http_budget_round_trip or demo_interface_http_reasons_and_history'
fi
if [[ -x "$project_dir/.tools/forge" ]]; then
  forge_bin="$project_dir/.tools/forge"
elif command -v forge >/dev/null 2>&1; then
  forge_bin="$(command -v forge)"
else
  echo '没有找到 Forge。安装 Foundry 后再运行：https://getfoundry.sh/getting-started/installation' >&2
  exit 1
fi

cd "$project_dir/contracts"
if [[ ! -f lib/forge-std/src/Test.sol ]]; then
  echo '缺少测试依赖。请在 contracts 目录执行：forge install --no-git foundry-rs/forge-std@v1.9.7' >&2
  exit 1
fi

if [[ "${1:-}" == "demo" ]]; then
  echo '本地演示：正常支付 100，预算从 500 变成 400；随后拦截错误收款地址。'
  exec "$forge_bin" test --match-test test_Demo_FirstPaymentThenWrongAddress -vv
fi
if [[ "${1:-}" == "timelock-demo" ]]; then
  echo '本地时间锁演示：管理员提交新地址；提前执行被拒绝；模拟推进 120 秒后执行。'
  exec "$forge_bin" test --match-test test_Demo_PayoutChangeWaitThenExecute -vv
fi
if [[ "${1:-}" == "pause-demo" ]]; then
  echo '本地暂停演示：管理员立即暂停；合法付款被拦截；等待模拟的 120 秒后恢复。'
  exec "$forge_bin" test --match-test test_Demo_PauseThenResumeAfterDelay -vv
fi
if [[ "${1:-}" == "expiry-demo" ]]; then
  echo '本地预算有效期演示：到期前付款成功；恰好到期及之后拒付，剩余预算不变。'
  exec "$forge_bin" test --match-test test_Demo_PayBeforeExpiryThenBlockAtAndAfterDeadline -vv
fi
if [[ "${1:-}" == "limits-demo" ]]; then
  echo '本地额度演示：每日限额拒付；跨天继续付款；Owner 延迟提额和立即降额。'
  exec "$forge_bin" test --match-test test_Demo_DailyLimitAndOwnerChanges -vv
fi
if [[ "${1:-}" == "agents-demo" ]]; then
  echo '本地 Agent 权限演示：立即撤销旧权限；新授权等待 120 秒；共用原有预算和每日上限。'
  exec "$forge_bin" test --match-test test_Demo_RevokeAgentThenAuthorizeNewAgent -vv
fi
if [[ "${1:-}" == "vendor-demo" ]]; then
  echo '本地供应商演示：119 秒未生效；120 秒执行登记；配好采购单后付款；停用即拒付；取消不可执行。'
  exec "$forge_bin" test --match-test test_Demo_VendorRegistrationThenDeactivation -vv
fi
if [[ "${1:-}" == "po-demo" ]]; then
  echo '本地采购单演示：等待后生效；甲乙不能互用预算；正常付款分别扣账；一份到期不影响另一份。'
  exec "$forge_bin" test --match-test test_Demo_MultiplePOsAndVendorOwnership -vv
fi
if [[ "${1:-}" == "po-budget-demo" ]]; then
  echo '本地采购单预算演示：降额保留已付；提额等待 120 秒；重复账单仍拒付；关闭取消提额并停止付款。'
  exec "$forge_bin" test --match-test test_Demo_POBudgetChangesThenClose -vv
fi
if [[ "${1:-}" == "period-demo" ]]; then
  echo '本地周期预算演示：每 30 天恢复一份额度；换日不补周期预算；余额不增加，剩余额度不累加，历史不清空。'
  exec "$forge_bin" test --match-test test_Demo_ThirtyDayBudgetAndHistory -vv
fi
if [[ "${1:-}" == "governance-demo" ]]; then
  echo '本地治理时间锁演示：9 类变更排队不生效；119 秒均拒绝执行；120 秒后逐项执行；取消或执行记录不可重放。'
  exec "$forge_bin" test --match-test test_Demo_AllGovernanceChangesNeedTimelock -vv
fi
if [[ "${1:-}" == "init-demo" ]]; then
  echo '空金库初始化演示：零登记/零授权/零资金；两轮时间锁配置；两家供应商付款各扣预算；余额与历史可核对。'
  exec "$forge_bin" test --match-test test_Demo_EmptyVaultInitializeThenTwoVendorsPay -vv
fi
exec "$forge_bin" test "$@"
