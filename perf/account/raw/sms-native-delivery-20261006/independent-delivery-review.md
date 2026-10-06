# 独立只读交付核验 · 2026-10-06

由 `/root/fitcoach_clients_sms/verify_delivery_evidence` 独立只读核验，没有修改文件、运行 GUI/Simulator/SDK、读取密钥或发送短信。

- `~/.local/bin/fitcoach` 实际指向已安装 `/Applications/上门体育.app/Contents/Resources/bin/fitcoach`。App 1.0.1（58）；CLI SHA256 `971aa8629e9242edda954f5f258adc7f2e9e473ded7d1c6278eb943b5afac782` 与 E2E 原件相同。App/CLI 严格签名核验均退出 0。
- E2E 脚本实际启动原 service FastAPI、临时 SQLite、真实 tenancy，使用原 `test_phone.lane` 再经 localhost 调用已装 CLI。最终 52 次命令、90 次断言执行通过；12 次 fake send、11 次 fake check。原生产 gateway 仍调用 `AliyunSmsAuth`，未发现产品测试分支。
- 当前正式 iOS archive 主 App、Watch、Widget 均为 1.0.1（7），三可执行 SHA 与 `ios-archive-identity.json` 逐项吻合，签名校验均退出 0；SDK 日志包含 `ARCHIVE SUCCEEDED`。
- 原 prepare-only 日志保留 Apple TLS 超时，边界记录保留原 exit 1；后续只读 preflight 的 JSON 正常且 stderr 为空，记录为 exit 0。共享 prepare-only 分支在 export/upload 之前退出。留存 ASC 回读 9 个 build，最高 6，未出现 7。

范围限制：90 次断言包含重复检查，并非 90 个独立场景；业务保持直接检查原学员名称及另一教练存在，不能外推为全部历史数据逐字段一致。原夹具还隔离 DB、鉴权环境、时钟与配置，不能称整个测试只 monkeypatch 一个对象。没有真实云短信符合本次替身结构，但不证明原生 GUI 或生产短信账号闭环完成。Apple 无 build 7 是留存回读时点的结论。原数字退出码由边界回执记录，日志及脚本分支相互印证；原日志本身不含单独退出码行。
