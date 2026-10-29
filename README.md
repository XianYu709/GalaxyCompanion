# GalaxyCompanion

GalaxyCompanion 是一个由 iPhone App 和自研 Wear OS App 组成的 Galaxy Watch 配套项目。目标是在不依赖 Android 手机或 Samsung Health 云历史的情况下，将自有 Watch App 采集的健康数据在用户手动触发时安全同步至 iPhone 与 Apple Health，并提供本地睡眠分析。NFC Lab 是独立的后续实验；实时展示、实时消息与通知转发不属于当前产品范围。

当前已完成 **BLE 真机连接 PoC**：iPhone 已在 Galaxy Watch6 Classic 上发现并连接自有 GATT 服务、读取设备能力。两端还具备系统 MITM 配对门、认证后的 cursor 增量同步、iPhone 本地去重/恢复、用户主动的 HealthKit 写入和本地睡眠估算。所有会依赖真实系统弹窗、Health Services 回调频率、低 MTU 分片、断线时序或 HealthKit 写入结果的部分，仍须用目标 iPhone 与 Watch 做 PoC，不能视为已发布承诺。

## 目录

- [`docs/MVP_TECHNICAL_SPEC.md`](docs/MVP_TECHNICAL_SPEC.md)：MVP 范围、可行性分级、验收门槛与产品边界。
- [`iOS/`](iOS)：可编译的 SwiftUI iPhone 启动工程。
- [`WearOS/`](WearOS)：可导入 Android Studio 的 Watch 启动工程与 BLE GATT 基础。
- [`Shared/Swift/`](Shared/Swift)：协议值类型、cursor 同步与健康数据映射策略；模拟 Watch 仅保留在自动化测试依赖中，不编入 iPhone App。

## 本地验证

```sh
cd Shared/Swift
swift test

cd ../../iOS
xcodebuild -project GalaxyCompanion.xcodeproj -scheme GalaxyCompanion \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Wear OS 已包含 Gradle 9.2.1 Wrapper。使用 Android Studio 导入 `WearOS/`，或在目录内执行 `./gradlew :app:assembleDebug`；调试 APK 输出为 `WearOS/app/build/outputs/apk/debug/app-debug.apk`，安装目标是 Galaxy Watch。

## 当前状态

- 用户已在 Galaxy Watch6 Classic 真机上验证 iPhone BLE 连接与能力读取。
- Watch 按 Health Services runtime capability 动态上报心率、步数、卡路里与距离支持情况；支持情况不等同于已授权或已采集。
- Watch 用户授权后会按 Health Services 的**运行时能力**选择被动日累计指标，以及可用的低频后台心率和步数/距离增量；数据先写入有界的手表私有存储。应用不显示即时心率，iPhone 也不自动拉取数据。
- iPhone 可对当前连接主动触发系统级安全配对校验；验证结果按 BLE 连接会话失效，重连后必须重新校验。
- 仅当当前 BLE 连接完成 MITM 配对门校验后，Watch 才将 `healthDataMode` 报为 `authenticatedMeasurement` 并接受健康同步请求；未验证连接不会传输健康数据。
- Watch 会根据实际 ATT MTU 缩小同步页面，并保留最近 2,000 条私有样本。只有容量淘汰真正造成缺口时，协议才会返回 `retentionGap`；iPhone 必须停止并要求用户在诊断确认后显式重设到手表返回的恢复 cursor，绝不静默跳过数据。日累计样本的正常修订不会被误判为缺口。
- iPhone 正式界面将“同步到 iPhone”和“写入 Apple Health”分开。只有来自当前认证连接的真实样本可被写入；`CALORIES_DAILY` 含基础代谢，仅在本应用展示，绝不伪装成活动能量。
- 本地睡眠仅使用已同步的低频心率与细粒度活动增量，输出保守的休息时段、预计睡眠时长与效率；数据不足、采样空档或只有日累计步数时明确不给结果，不复刻三星的睡眠分期或评分。
- 共享 Swift 测试覆盖能力载荷、分片协议、cursor / 批次 / 去重、HealthKit 累计值修订/删除和本地睡眠固定样本。

## 当前下一步

下一步在 Galaxy Watch6 Classic 与 iPhone 真机验证系统 MITM 加密配对/拒绝配对、低 MTU 分片、离线积压、断连续传、重复批次、HealthKit 部分写入恢复，以及后台心率/活动增量的实际回调覆盖。睡眠继续按真实数据做 PoC；NFC 保持独立实验，不阻塞基础健康闭环。
