# CLAUDE.md · fitcoach-ios

> 面向使用者的说明在 `README.md`。本文件只管**改代码前要知道的事**。

**纯客户端，后端一行都不改。** 后端 = `~/Dev/services/fitcoach`（线上
`https://fit.tianli.cyou`，`FITCOACH_COACH_AUTH=multi`）。要改行为先问：
这是客户端问题还是后端问题？业务判据（余额、状态机、档期、硬拒）**全部在后端 domain.py**，
客户端复制一份判据 = 两边必然漂移。

## 分层

| 文件 | 职责 | 硬约束 |
|---|---|---|
| `Sources/Models.swift` | Codable 结构 + 词表 | 字段名**逐字**照 `domain.py` 的 dataclass，禁猜 |
| `Sources/TimeKit.swift` | 时区与字符串日期互转 | 只 import Foundation（契约 harness 要单独编它） |
| `Sources/API.swift` | HTTP + 凭证 + 错误协议 | 零业务判断 |
| `Sources/*View.swift` | SwiftUI 界面 | 不做「哪些能改」的本地判断，交给后端报错 |

## 五条踩过的坑

1. **cookie 要自己拼。** `/api/login` 返回的是 cookie **值**，不是 `Set-Cookie`。
   URLSession 的 cookie jar 帮不上忙，每个请求手动 `Cookie: fc_coach=…`。
2. **全站收 Form，不收 JSON。** 发 JSON body 会 422，而 422 在客户端长得像「密码错了」。
3. **409 与 400 语义不同。** 409 = 软警告可 `force=on` 重试；400 = 硬拒，force 也不放行。
   把 400 也引导去「强制重试」会让教练进死循环。
4. **`is_active` 每次都必须提交。** 学员与地点的更新端点缺这个字段 = 按停用处理，
   而停用学员会**同时吊销**他的链接。这条不报错，只是数据静默变了。
5. **时区是 Asia/Shanghai，不是手机的。** 课程时间存本地墙钟字符串，DatePicker
   必须用 `TZ.zone` 格式化，否则人在别的时区时「今天」会差一天。

## 改完要跑什么

```bash
xcodegen generate --spec project.yml   # 增删了 Sources 下的文件才需要
./ref/run                              # 契约对账，49 项，必须全绿
```

`ref/run` 自己起一台临时后端（临时库，跑完删），并且**端口被占用就拒绝跑** ——
2026-08-27 实测：遗留的 uvicorn 占着端口时 harness 会打到另一台服务器上全绿。
守卫哑掉比守卫报红危险得多，别把这道门去掉。

## 上游已知问题（不是本 app 的）

`~/Dev/services/fitcoach/seed.py` 在 2026-08-17 多租户改造后没跟着改，
调 `domain.create_location` / `create_student` 时缺 `coach_id` 参数，**跑不起来**。
本 app 的契约 harness 因此不用 seed，自己经 API 建数据。
