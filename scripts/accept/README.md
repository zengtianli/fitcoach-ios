# 固定验收

在仓库根目录由 Chapter 执行并写入证据：

```bash
~/Dev/.venv/bin/python ~/Apps/chapter/engine/app_sop.py accept --app fitcoach-ios \
  --check functionality --check recovery --check privacy --json
```

`project.yaml` 的 `sop.accept` 分别登记 `bash scripts/accept/<name>.sh`。
公共运行时 `_common` 提供临时目录、生产 Swift API/模型编译和隔离后端。
需要本机 Xcode 命令行工具、共享 `xcode_env.sh`，以及同产品的
既有 Python 与后端依赖；`scripts/test_runtime.py` 先核后端 venv，再核总部
`~/Dev/.venv`，不创建或修改兄弟仓环境；可以用 `FITCOACH_TEST_PYTHON` 显式指定，
用 `FITCOACH_TEST_BACKEND` 指定另一份本地后端源码。后端只读复用，测试数据在临时数据库内创建并清除。

- functionality：复用 `ref/main.swift`，检查登录、账户、排课、课时、体测及学员端等现有契约。
- recovery：真实 API 客户端连接隔离后端和本地故障服务，验证拒绝后的数据保全、错误分类及故障后的重试。
- privacy：真实 API 客户端连接隔离后端，验证凭证、教练租户和学员只读边界。

三项都不连接线上账户、不打开 App 或模拟器、不操作输入设备。它们证明
当前客户端 API/模型的实际执行行为，不证明已装 iPhone 的版本、SwiftUI 操作、
真机权限或资源占用。记录由 `app_sop.py` 自动生成，不手工修改
`perf/delivery-evidence.json` 或 `perf/acceptance/`。

原契约回归仍可用 `bash ref/run`。本轮新增验收只走上述 Chapter 命令，
避免将手工执行结果冒充固定验收证据。

`account_lifecycle` 由 `scripts/accept/account_lifecycle.py` 执行：先沿 `cli/build.sh`
编当前 CLI 与原 sim_lane 候选，再复用后端现有 `test_phone.lane` 做隔离注册、登录、
找回、改密、换绑、退出、注销及滥用防护回归。实际产品的 `--account-self-test` 挂载真实
SwiftUI 页面，以测试专用 Environment 挂钩直接调用原按钮动作、读取真实 State；Mac 离屏，
iPhone 用共享无窗口模拟器，并保留渲染原片和完整候选文件 SHA。入口仅 DEBUG、测试 bundle id
和 127.0.0.1 同时成立时可运行；使用不落盘 Session，测试身份绕过正式 Keychain，Release 不含该入口。
原始断言附 SHA，并明确标记 fake SMS、0 条真实发送；真实收信未完成时总验收仍失败，
不会把本机隔离链路或 CLI 回归冒充苹果设备实测或真实短信投递。环境推迟退出75并保留原始原因。

`scripts/perf/prepare_builds.py` 只调用总部原 SDK 缓存和 `sim_lane.build` 构建槽，
预备资源补测的真实 Release 回执；不启动模拟器、不采样、不写资源通过证据，
输出 `build/perf/current-builds.json` 与摘要，可交回 Chapter 原队列按原门槛消费。

`launch_mac` 通过后，`scripts/media/mac_store_shot.py` 只从本轮真实离屏原片生成
商店规格副本，保留原片 SHA 和实际日程/余额内容的裁切坐标；它不重建侧栏界面，也不上传或送审。

`native_ui` 是显式候选入口：串行复用原构建脚本准备当前 Mac/iPhone 包与完整文件回执，
再执行产品自己的 `--ui-self-test`，默认不上屏、不进 Dock、不合成输入。真实设置面板、
刷新/关闭路径、同步与更新的检查/截图原件沿 `product_basics.py` 输出；这不会把候选记成已安装。
`product_basics.py` 默认仍验已装 Mac 版；候选使用 `--app`、`--receipt`、`--ios-receipt`。

`media_playback` 薄入口只展开本仓登记的完整媒体 glob，然后交给 Chapter 原生解码/播放验收，
避免旧播放器把 glob 当不存在的文件而漏掉本地视频；QA 数据库/进程日志不作为媒体输入。

审核账号的只读连通核验：

```bash
~/Dev/.venv/bin/python scripts/accept/review_access.py --out build/review-access.json
```

仅从原受保护配置加载专用审核凭据，对默认HTTPS服务做一次邮箱登录及教练业务GET，
拒绝重定向，手动拼接会话cookie；没有短信请求、数据修改或自动重试，输出不含凭据和业务内容。
登录失败后先读HTTP或网络原因，不循环试密码。此命令只证明运行时的API访问范围，
不生成Chapter验收通过标志，也不代替隔离原生页面、正式Store包或审核排队证据。
