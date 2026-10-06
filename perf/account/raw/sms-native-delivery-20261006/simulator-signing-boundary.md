# Simulator 签名诊断边界

原最终 Debug SDK 包严格复用成功、真实登录页可安装启动；其构建设置为 `CODE_SIGNING_ALLOWED=NO`，SavedLogin 的 Keychain 读取在该环境返回 `-34018`。

为消费对照从不可变原件派生独立副本，用本机 Apple Development 身份签名并使用正式归档实际主 App entitlements；未改原 SDK package/receipt、Mac 安装包、正式 iOS 归档或产品源码。派生签名静态 `codesign --verify --deep --strict` 通过，但实际 Simulator 启动遭宿主 taskgated 拒绝。两份 `.ips` 原件均为 `SIGKILL (Code Signature Invalid)`、`termination.namespace: CODESIGNING`、`Taskgated Invalid Signature`，未进入账号业务。运行 boot 8.0 秒、install 22.9 秒，launch 未返回 process handle，未产生截图；原 Session 退出自动关闭设备并释放锁。没有把派生包失败改写成产品或生产账号 PASS。

随后只读 `xcodebuild -showBuildSettings -sdk iphonesimulator CODE_SIGNING_ALLOWED=YES` 核实际 Xcode Simulator 配置：

```
CODE_SIGN_CONTEXT_CLASS = XCiPhoneSimulatorCodeSignContext
CODE_SIGN_INJECT_BASE_ENTITLEMENTS = YES
ENTITLEMENTS_ALLOWED = NO
ENTITLEMENTS_DESTINATION = __entitlements
ENTITLEMENTS_REQUIRED = NO
PROVISIONING_PROFILE_REQUIRED = NO
```

`otool -l` 核原 base 不含 `__entitlements` 段。设备签名授权与 Simulator entitlements 路径不同，是这次派生方法的环境边界；尚无消费者证据证明具体哪个 entitlement 引发 taskgated 拒绝。总部没有可核实的现成合法 Simulator Mach-O entitlement 派生接口，因此按 Root 指示收束诊断，没有手搓 linker、增加权限、绕系统安全或重编全部成功包。

正式归档仍独立验证三包签名有效，并用实际 profile 授权列表核实际 group。Apple 说明 profile 授权和签名声明分别检查，不能拿 Simulator 的测试签名代替实机授权：[TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。实体消费未验，不能将其声明为生产 Keychain PASS。

最后使用原成功 unsigned base 和现成 `-fitcoach.screen phone-account` 隔离入口拍真实 Form；只使用原测试夹具的合成 cookie、临时 DB/localhost，没有真手机号、验证码或真实用户 cookie 进入 argv。该深页不经过 SavedLogin，页面图只证明实际账号 GET 与 Form 布局，不证明 unsigned 环境中的 Keychain 能力。
