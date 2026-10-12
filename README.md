# OnlyContacts 3.0.0

只让**通讯录里**的号码打进来；陌生号码直接打不进，并可由运营商「遇忙转移」把它们转走（可一键设置）。

给 iPhone 14 Pro / iOS 16.2 / RootHide（roothide）越狱设备使用。

---

## 功能

| 功能 | 说明 |
|---|---|
| 通讯录放行 | 通讯录里的号码正常响铃 |
| 陌生号拒接 | 判定在 `callservicesd` 的来电过滤器里做，铃根本不响；对方听到"忙音" |
| 遇忙转移（自动化） | 面板里填一个「停机号」，一键把运营商「遇忙转移」设到它 —— 被拒接的呼叫会被运营商转过去，主叫听到停机/空号提示 |
| 例外放行 | 短号/急呼（110/119/120…）永远放行；可选"连打两次放行"、尾号匹配、隐号放行 |
| 面板 + 日志 | 设置 App 里配置，2 秒内生效；决策日志写入 `/var/mobile/Library/Logs/onlycontacts.log`（RootHide 下在隐根内同路径） |

## 安装

1. 装 PreferenceLoader（RootHide Bootstrap 一般自带）。
2. 装对应架构的 deb：
   - **A12 及以后（arm64e）**：`com.rna.onlycontacts_3.0.0_iphoneos-arm64e.deb`
   - 其他（arm64）：`com.rna.onlycontacts_3.0.0_iphoneos-arm64.deb`
3. 安装后建议 `launchctl kickstart -k system/com.apple.callservicesd`（或重启一次）。

## 使用

设置 → OnlyContacts：

- 「停机号（转移目标）」填要转去的号码
- 「一键设置遇忙转移」→ 系统同款通道直接设置（无需拨码）
- 若因运营商限制失败 → 面板底部有拨号盘备用代码：
  - 开启：`**67*停机号#`
  - 关闭：`##67#`
  - 取消所有转移：`##002#`

## 工作原理（简）

- 注入 `callservicesd`，hook `CSDCallFilterController`：
  - `shouldFilterIncomingCall:` —— 判定"非通讯录 → 过滤"
  - `shouldRestrictAddresses:…` —— 10 秒护栏内"真拒接"（对方听到忙音）
- 通讯录匹配双保险：系统 `isUnknownCall:` + 直读 AddressBook.sqlite（尾号匹配）
- 一键转移：面板进程调用 `CoreTelephonyClient getUserDefaultVoiceSubscriptionContext:`
  + `CTCallForwardingValue(reason=MobileBusy, clss=Voice, enabled, saveNumber)`
  + `saveCallForwardingValue:value:completion:`（与系统"设置→电话→呼叫转移"同款链路）

## 构建（GitHub Actions）

推送到 `main` 自动触发 `.github/workflows/build.yml`：
macos-14 + roothide/theos + theos/sdks + ldid，矩阵构建 `roothide`（arm64e）与 `rootless`（arm64），产物在 Actions artifacts。

## 回滚

- 卸 deb 即回滚
- 取消运营商转移：拨号盘 `##002#`
