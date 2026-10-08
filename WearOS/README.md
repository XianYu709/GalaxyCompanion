# GalaxyCompanion Wear OS

这是 Watch 端的 Sprint 0/1 工程基础：Wear Compose 启动页，以及应用自有的 BLE GATT 服务与广播契约。它不连接 Samsung 私有协议，也尚未开始传感器采集、数据存储或 HealthKit 同步。

## 构建前提

- Android Studio 与 Android SDK API 36。
- JDK 17。
- 已提交 Gradle 9.2.1 Wrapper；在 `WearOS/` 目录运行 `./gradlew :app:assembleDebug`。

调试 APK 输出到 `app/build/outputs/apk/debug/app-debug.apk`。该 APK 要安装到 Galaxy Watch，不是 iPhone。

## 第一轮真机验证

1. 将 debug APK 安装到 Galaxy Watch，打开 `GalaxyCompanion`。
2. 点按“启动 BLE”，并允许手表请求的蓝牙权限。
3. 画面显示“BLE 服务正在广播”后，在 iPhone App 中点按“开始搜索手表”。
4. 在连接成功前保持 Watch App 位于前台；后台持续广播将在后续的服务与电池策略阶段处理。

`WatchGattServer` 与 `WatchBleAdvertiser` 只能在 UI 层完成 Android 蓝牙运行时授权后启动。第一轮真机 PoC 必须验证两者在目标 Galaxy Watch 上能否同时运行。
