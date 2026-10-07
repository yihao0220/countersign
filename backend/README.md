# Countersign 本地整合后端

基础上传、SQLite 持久化与 mock worker 来自 hyptonize/-hackathon@e2b060ef04e0e9e466168bb79f7cb39e39d9a6bc。本次新增 /api/team、/api/attempts、/api/registry、/api/ledger、/api/local 等兼容接口。

从项目根目录用 `./local.sh start` 运行整套系统。脚本为后端设置本地 manifest 和独立数据目录，不需钱包私钥或模型密钥。只有配置 COUNTERSIGN_LOCAL_MANIFEST 时启用本地合约适配。

从项目根目录运行 `.venv/bin/python -m pytest -q backend/tests`。其中本地整合测试使用独立临时 Anvil，不操作页面正在使用的链。

未配置本地 manifest 时，原始 /api/invoices 上传、文字和查询接口仍可使用，`python -m app.workers.pipeline --mock` 只处理原始 mock 作业。不要把该 mock worker 与本地整合回执混淆。全套运行由 local.sh 管理，不需另开 mock worker。

完整说明见 [LOCAL_TEST.md](../docs/LOCAL_TEST.md)，依赖锁定在 requirements-local.lock。数据库、上传和运行日志均不提交 Git。
