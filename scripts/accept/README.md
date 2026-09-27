# 固定验收

在仓库根目录由 Chapter 执行并写入证据：

```bash
~/Dev/.venv/bin/python ~/Apps/chapter/engine/app_sop.py accept --app fitcoach-ios \
  --check functionality --check recovery --check privacy --json
```

`project.yaml` 的 `sop.accept` 分别登记 `bash scripts/accept/<name>.sh`。
公共运行时 `_common` 提供临时目录、生产 Swift API/模型编译和隔离后端。
需要本机 Xcode 命令行工具、共享 `xcode_env.sh`，以及同产品的
`../../service/.venv/bin/python` 和后端依赖；可以用 `FITCOACH_TEST_BACKEND`
指定另一份本地后端源码。后端只读复用，测试数据在临时数据库内创建并清除。

- functionality：复用 `ref/main.swift`，检查登录、账户、排课、课时、体测及学员端等现有契约。
- recovery：真实 API 客户端连接隔离后端和本地故障服务，验证拒绝后的数据保全、错误分类及故障后的重试。
- privacy：真实 API 客户端连接隔离后端，验证凭证、教练租户和学员只读边界。

三项都不连接线上账户、不打开 App 或模拟器、不操作输入设备。它们证明
当前客户端 API/模型的实际执行行为，不证明已装 iPhone 的版本、SwiftUI 操作、
真机权限或资源占用。记录由 `app_sop.py` 自动生成，不手工修改
`perf/delivery-evidence.json` 或 `perf/acceptance/`。

原契约回归仍可用 `bash ref/run`。本轮新增验收只走上述 Chapter 命令，
避免将手工执行结果冒充固定验收证据。
