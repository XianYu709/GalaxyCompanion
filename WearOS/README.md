# GalaxyCompanion Wear OS

这是 Watch 端的 Wear Compose 应用、自有 BLE GATT 服务和 Health Services 基础采集实现。它不连接 Samsung 私有协议。健康数据先保存在手表本地；只有当前 BLE 连接通过系统 MITM 配对门后，iPhone 才能用自有 GATT 请求增量同步。

## 构建前提

- Android Studio 与 Android SDK API 36。
- JDK 17。
- 已提交 Gradle 9.2.1 Wrapper；在 `WearOS/` 目录运行 `./gradlew :app:assembleDebug`。

调试 APK 输出到 `app/build/outputs/apk/debug/app-debug.apk`。该 APK 要安装到 Galaxy Watch，不是 iPhone。

## BLE 连接

1. 将 debug APK 安装到 Galaxy Watch，打开 `GalaxyCompanion`。
2. 点按“启动 BLE”，并允许手表请求的蓝牙权限。
3. 画面显示“BLE 服务正在广播”后，在 iPhone App 中点按“搜索我的手表”。
4. 在连接成功前保持 Watch App 位于前台；后台持续广播将在后续的服务与电池策略阶段处理。
5. iPhone 显示连接成功后，点按“请求 / 验证蓝牙配对”，并按 iPhone 与 Watch 的系统提示完成安全配对。
6. iPhone 显示“当前连接已验证”后，可确认这条连接已通过 GATT 加密配对门；断开并重连后需再次验证。

`WatchGattServer` 与 `WatchBleAdvertiser` 只能在 UI 层完成 Android 蓝牙运行时授权后启动。第一轮真机 PoC 必须验证两者在目标 Galaxy Watch 上能否同时运行。

## 本地健康采集

1. 点按“刷新健康能力”，查看 Health Services 在当前手表上报告支持的指标。
2. 点按“开启本地健康记录”，按系统提示授予心率或活动识别权限。
3. 当前构建按 Health Services 的运行时能力尝试采集：被动日累计步数/距离/总能量，以及（若设备报告支持）低频后台心率与细粒度步数/距离增量。样本存在手表私有的有界缓存中；本应用不显示或传输即时心率流。
4. 细粒度活动增量与日累计值会带不同的时间语义：前者可供 iPhone 做保守的本地睡眠分析，后者只用于日指标展示和安全归一化，二者不会相互替代。
5. 可用“暂停本地健康记录”停止新的被动采集；已有缓存不会被删除。

能力探测不代表用户已授权、数据已开始采集或传感器回调已在真机验证。Health Services 会按系统选择的频率批量交付后台数据，应用不假定固定采样周期；如果后台心率或活动增量未被目标手表报告支持，iPhone 会明确显示睡眠数据不足。完成配对门后，iPhone 可以经加密 GATT 以 cursor 分页请求本地样本；手表会按当前 ATT MTU 缩小批次，而不会跳过记录。系统配对弹窗、MITM 属性、低 MTU 分片和断连重连行为仍需用目标 Watch 与真实 iPhone 完成 PoC。

手表只保留最近 2,000 条私有样本。只有缓存容量实际淘汰过记录、且 iPhone 的本地 cursor 早于可安全恢复水位时，手表才会返回 `retentionGap`；日累计数据的正常修订不会触发该错误。iPhone 必须停止同步并在诊断中要求用户明确确认后，将同步 cursor 重设为手表返回的恢复水位；不得自动推进到最新值来掩盖丢失区间。
