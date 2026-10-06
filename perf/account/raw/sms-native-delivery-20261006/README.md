# 上门体育短信版本交付原件 · 2026-10-06

本目录只记录原生与 CLI。本产品小程序已依用户要求归档。

- Mac 已安装 `/Applications/上门体育.app` 1.0.1（58），签名/沙盒/hardened、universal。原共享安装器 no-launch 同卷事务替换；旧包 `/Applications/.上门体育-install-em445en6/Previous.app`，事务 receipt 同目录。`~/.local/bin/fitcoach` 已指向包内 CLI。证据 `signed-mac-candidate.json`、安装日志、`installed-mac-cli-contract.json`（24 合同桩命令）、`installed-cli-online-hints.json`（生产只读 hints，未发送）。
- 已装 CLI 直接连接实际 FastAPI/tenancy/SQLite 的原隔离 fixture，52 次命令、90 次断言执行通过；12 次 fake send、11 次 fake check、0 真实短信。覆盖注册、绑定、双号换绑、短信登录及补独立证明、找回、无密码账号设密、会话消歧/轮换、学员保留、预算/未知同 ID 与临时租户注销。`installed-cli-service-e2e.json` 和复现脚本；失败尝试也保留。断言次数含重复检查，业务保持直接核原学员名称及另一教练存在，不外推为所有业务字段不变。
- iPhone 原成功 Debug 包严格复用、安装、启动、离屏登录页图：`iphone-login-run.json`、`iphone-sms-login.png`。显示短信登录/注册/找回入口；unsigned 包 SavedLogin Keychain 返回 -34018，原现象保留。账号安全 Form 用同一原 base/原入口、临时真实服务与合成 cookie 实际加载；`unsigned-phone-form-consumer.json`、`iphone-unsigned-phone-account.png`。自然 load 14.38 按原门准入，boot 8.4s/install 21.7s/稳定 6.089s，1206×2622，随后关闭。0 fake/real SMS、没有 UI 输入或 Mac 用户偏好操作。
- 独立签名模拟器副本静态验签通过，实际启动被宿主 Taskgated 拒签；原 crash/失败回执保留，见 `simulator-signing-boundary.md`。未修改原成功包/receipt，未吞错误或重编。生产 Mac/正式 iOS 包签名独立有效；没有声称模拟器 Keychain 或生产账号 PASS。
- 正式 iOS 归档 `/private/tmp/ios-testflight/FitCoach-ios.xcarchive`，主 App/Watch/Widget 均 1.0.1（7）、Team B9LJH93LA4，Xcode 27A266a/iphoneos27.0；三包 SHA/实际 entitlements/profile/严格签名在 `ios-archive-identity.json`。SDK 原日志含 `ARCHIVE SUCCEEDED`。prepare-only 原任务因归档后 Apple TLS preflight 超时 exit 1，原失败不改写；仅补明确 DEVELOPER_DIR 后的只读 preflight 实际 exit 0，`ios-archive-preflight-toolchain.json`。留存 ASC 回读最高 build 6、未新增 7，见 `ios-prepare-boundary.json` 与原始文本。

批准上传后复用上述归档：

```bash
bash /Users/tianli/Dev/tools/dev/lib/tools/macapp/ios/push-testflight.sh --testflight-only --upload-prepared /Users/tianli/Apps/fitcoach/ios/01-源程序
```

该后续命令会先再次实际 preflight 再上传；本次没有执行 export/upload、挂商店草稿、分发或 Git push。实体 iPhone 当前 tunnel/DDI 不可用，未真机安装；采用已接受的模拟器范围。真实 PNVS/生产 H5 证据由 Root/service 单独维护，不与此隔离验收混为生产手机账号闭环。

本机接续说明保存在原 ignored `handoffs/sms-clients-20261006.md`。独立只读复核见 `independent-delivery-review.md`。
