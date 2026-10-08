# GalaxyCompanion

GalaxyCompanion 是一个由 iPhone App 和自研 Wear OS App 组成的 Galaxy Watch 配套项目。目标是在不依赖 Android 手机或 Samsung Health 云历史的情况下，将自有 Watch App 采集的健康数据安全同步至 iPhone 与 Apple Health，并逐步提供本地睡眠分析、只读通知与 NFC Lab。

当前处于 **Sprint 1：BLE 地基与模拟同步验证**。蓝牙、健康数据、通知和 NFC 均未对用户承诺可用，必须先完成对应的真机 PoC。

## 目录

- [`docs/MVP_TECHNICAL_SPEC.md`](docs/MVP_TECHNICAL_SPEC.md)：MVP 范围、可行性分级、验收门槛与产品边界。
- [`iOS/`](iOS)：可编译的 SwiftUI iPhone 启动工程。
- [`WearOS/`](WearOS)：可导入 Android Studio 的 Watch 启动工程与 BLE GATT 基础。
- [`Shared/Swift/`](Shared/Swift)：协议值类型、cursor 同步、内存样本库与模拟 Watch；可在 macOS 上运行测试。

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

## 当前已验证

- iOS 模拟器会切换至 Fake Watch：可演示连接状态、能力协商，以及使用 cursor / 批次 / 去重逻辑的模拟健康同步。该数据不写入 Apple Health，也不是蓝牙联调结果。
- Watch 端会在自有 GATT 服务注册完成后才启动可连接广播；iPhone 可读取 `capabilities` 特征获得基础能力集。
- 共享 Swift 测试已覆盖能力载荷编解码、Watch GATT 返回的 JSON 兼容性、断线续传与重复批次去重。

## 当前下一步

在目标 iPhone 与至少一块 Galaxy Watch 上验证自有 GATT 服务的广播、发现、连接、MTU、断连与恢复。该 PoC 通过前，不开始 HealthKit、Dashboard、睡眠算法、通知转发或 NFC 模拟功能。
