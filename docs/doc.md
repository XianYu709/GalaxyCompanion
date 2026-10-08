可以。按你现在的需求，我建议直接把项目收敛成一个**“健康 + 通知 + 睡眠分析 + NFC 实验室”的 iPhone/Galaxy Watch Companion**，不要再碰 Galaxy Wearable 那些高风险功能。

而且我专门按你后面准备用 **Codex + vibe coding** 的方式来设计，所以下面不是泛泛的产品规划，而是可以直接拿去建仓库、拆任务、让 Codex 一步步实现的规格。

## 一、先把最终产品范围锁死

### P0：必须做

| 模块      | 功能                                                       |
| --------- | ---------------------------------------------------------- |
| 连接      | Galaxy Watch 扫描、连接、重连、连接状态                    |
| 健康      | 步数、心率、IBI、HRV、活动卡路里、距离、楼层               |
| 健康增强  | SpO₂、皮肤温度                                             |
| 运动      | Workout 基础记录                                           |
| 睡眠      | 睡眠开始/结束、总时长、阶段数据/阶段推断、HR/SpO₂/温度关联 |
| HealthKit | 写入 Apple Health                                          |
| 通知      | iPhone App 通知 → Galaxy Watch                             |
| 设置      | App 自己的设置、数据来源、同步频率                         |
| 诊断      | Watch 型号、系统、BLE、能力矩阵、错误日志                  |

### P1：做出来很好

| 模块     | 功能                              |
| -------- | --------------------------------- |
| 健康增强 | EDA、BIA、MF-BIA                  |
| ECG      | 读取/展示原始或可用结果           |
| PPG      | 原始 PPG 数据采集                 |
| 睡眠     | 更完善的睡眠评分、阶段算法        |
| 趋势     | 7/30 天趋势，但只基于本地已有数据 |
| 通知     | 更好的 App 过滤、通知分类         |

### P2：实验性质

| 模块 | 功能                                |
| ---- | ----------------------------------- |
| NFC  | iPhone 扫描 NFC                     |
| NFC  | 保存 NFC/NDEF 信息                  |
| NFC  | 把可支持的 NFC profile 下发给 Watch |
| NFC  | Galaxy Watch HCE 模拟               |
| NFC  | Reader 能力检测                     |

### 明确不做

```
❌ 找手表
❌ eSIM
❌ 支付
❌ Samsung Account
❌ Galaxy Store
❌ OTA
❌ 完整手表设置
❌ 电话
❌ 短信发送
❌ 短信回复
❌ 三星云端历史数据
❌ Samsung Health 云端备份
```

这会让整个项目从“几乎不可能完整复刻”变成一个**非常现实的产品**。

------

# 二、最重要的架构决定：不要用 Wear OS Data Layer

这个我专门核了一遍官方文档。

Google 的 Wearable Data Layer **只能用于 Wear OS ↔ Android 手机**；如果 Wear OS 手表配对 iPhone，Data Layer 不工作。[Android Developers](https://developer.android.com/training/wearables/data/data-items?utm_source=chatgpt.com)

所以我们的主通信必须是：

```
Galaxy Watch
    ↕
Bluetooth LE / GATT
    ↕
iPhone
```

也就是：

### Watch

```
BluetoothGattServer
```

### iPhone

```
CoreBluetooth
CBCentralManager
CBPeripheral
```

这一点不要让 Codex 自己改成 Data Layer。

------

# 三、正式架构

我建议直接做一个 monorepo：

```
GalaxyWatchCompanion/
│
├── iOS/
│   ├── App/
│   ├── Core/
│   │   ├── BLE/
│   │   ├── Protocol/
│   │   ├── Health/
│   │   ├── Sleep/
│   │   ├── Notifications/
│   │   ├── NFC/
│   │   ├── Storage/
│   │   └── Diagnostics/
│   │
│   ├── Features/
│   │   ├── Dashboard/
│   │   ├── Health/
│   │   ├── Sleep/
│   │   ├── Notifications/
│   │   ├── NFC/
│   │   └── Settings/
│   │
│   └── Tests/
│
├── WearOS/
│   ├── app/
│   │   ├── ble/
│   │   ├── health/
│   │   ├── sensors/
│   │   ├── sleep/
│   │   ├── storage/
│   │   ├── nfc/
│   │   ├── protocol/
│   │   └── diagnostics/
│   │
│   └── tests/
│
├── Shared/
│   ├── protocol/
│   ├── schemas/
│   └── docs/
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── PROTOCOL.md
│   ├── HEALTH_MATRIX.md
│   ├── SLEEP_ENGINE.md
│   ├── NFC.md
│   └── DEVICE_COMPATIBILITY.md
│
└── README.md
```

------

# 四、技术栈

这是我建议 Codex 直接照着搭的。

## iPhone

### 基础

```
Swift 6.2.x
SwiftUI
Observation
Swift Concurrency
```

目前 Xcode 26.3 对应 Swift 6.2.3，并包含 iOS 26.2 SDK。[Apple 开发者](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes?changes=l_4&utm_source=chatgpt.com)

### Bluetooth

```
CoreBluetooth
CBCentralManager
CBPeripheral
```

并且一定打开：

```
bluetooth-central
```

以及 state preservation / restoration。

Apple 明确支持 CoreBluetooth 的后台事件唤醒和状态恢复，但 App 仍可能被系统终止，因此不能把 iOS 当成一个永远运行的 Android Service。[Apple 开发者](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html?hl=ru&utm_source=chatgpt.com)

### Health

```
HealthKit
HKHealthStore
HKQuantitySample
HKCategorySample
HKWorkout
HKStatisticsQuery
HKSampleQuery
HKObserverQuery
```

HealthKit 的标准入口就是 `HKHealthStore`，负责读写健康数据和权限。[Apple 开发者](https://developer.apple.com/documentation/healthkit/hkhealthstore?utm_source=chatgpt.com)

### NFC

```
CoreNFC
NFCNDEFReaderSession
NFCTagReaderSession
NFCISO7816Tag
NFCISO15693Tag
NFCMiFareTag
NFCFeliCaTag
```

Apple 的 Core NFC 当前支持 NDEF，以及 ISO 7816、ISO 15693、FeliCa、MIFARE 等 Tag Reader API。[Apple 开发者](https://developer.apple.com/documentation/corenfc/?utm_source=chatgpt.com)

### 本地数据库

我建议：

```
SwiftData
```

足够了。

不要第一版就引入复杂数据库库。

------

# 五、Wear OS 技术栈

## 基础

```
Kotlin 2.4.20
Android Studio Rabbit 1 2026.2.1
JDK 17
Gradle Kotlin DSL
compileSdk 36
targetSdk 36
minSdk 30
```

Kotlin 2.4.20 是 2026 年 9 月的当前稳定版本。[Kotlin](https://kotlinlang.org/docs/releases.html?utm_source=chatgpt.com)

Android 16 是 API 36，官方当前建议 compile/target 36。[Android Developers](https://developer.android.com/about/versions/16/setup-sdk?authuser=111&utm_source=chatgpt.com)

Android Studio 当前 stable 已进入 Rabbit 1 / 2026.2.1。[Android Developers](https://developer.android.com/studio/releases?utm_source=chatgpt.com)

------

## UI

```
Jetpack Compose for Wear OS
Wear Compose Material 3
```

当前 Wear Compose 稳定版已经到 **1.7.1**；Google 也建议用 Material 3，而不是老的 Wear Compose Material。[Android Developers](https://developer.android.com/jetpack/androidx/releases/wear-compose?authuser=002&utm_source=chatgpt.com)

------

## 健康

第一层：

```
androidx.health:health-services-client:1.1.0
```

目前 1.1.0 是稳定版，2026-09-23 发布。它包含 ExerciseClient、MeasureClient、PassiveMonitoringClient 等。[Android Developers](https://developer.android.com/jetpack/androidx/releases/health?utm_source=chatgpt.com)

第二层：

```
Samsung Health Sensor SDK 1.4.1
```

三星目前的 SDK 是 1.4.1，支持 Galaxy Watch4 及以后。[Samsung开发者](https://developer.samsung.com/health/sensor/process.html?utm_source=chatgpt.com)

它能提供：

```
Accelerometer
BIA
ECG
EDA
Heart Rate
IBI
MF-BIA
PPG Green
PPG Red
PPG IR
Skin Temperature
SpO₂
Sweat Loss
```

而且 HR/IBI、PPG、加速度、皮温等有 continuous tracker；BIA、ECG、SpO₂ 等主要是 on-demand。[Samsung开发者](https://developer.samsung.com/health/sensor/guide/introduction.html?utm_source=chatgpt.com)

------

# 六、很重要：Samsung Health Sensor SDK 要单独处理

这一点 Codex 项目文档里一定写上。

三星现在要求：

> 使用 Samsung Health Sensor SDK 的正式发布 App，需要先走 partner request / partner approval。

否则只能用 Health Sensor Service 的 developer mode。[Samsung开发者](https://developer.samsung.com/health/sensor/process.html?utm_source=chatgpt.com)

所以架构必须设计成：

```
HealthRepository
      │
      ├── WearHealthServicesProvider
      │
      └── SamsungSensorProvider
```

这样没有 Samsung SDK 的情况下，基础功能仍然可以编译、运行和测试。

正式分发以后，再把高级传感器打开。

------

# 七、健康模块具体任务

## `HealthRepository`

统一定义：

```
HealthMetric
HealthSample
WorkoutSample
SleepSample
SensorReading
```

例如：

```
HealthMetric:
    steps
    heartRate
    ibi
    hrv
    activeCalories
    distance
    floors
    spo2
    skinTemperature
    respiratoryRate
```

每条数据必须带：

```
source
timestamp
startTime
endTime
unit
accuracy
```

------

# 八、健康同步协议

我建议不要让 UI 直接碰 BLE。

要这样：

```
UI
 ↓
HealthSyncCoordinator
 ↓
WatchTransport
 ↓
BLETransport
 ↓
Protocol
 ↓
Galaxy Watch
```

Watch：

```
Sensor
 ↓
HealthRepository
 ↓
LocalDatabase
 ↓
SyncService
 ↓
GATT Server
```

------

# 九、Watch 必须本地缓存健康数据

这是整个产品稳定性的核心。

不要设计成：

```
Watch测到数据
 ↓
立即发 iPhone
```

应该：

```
Sensor
 ↓
Local DB
 ↓
BLE
 ↓
iPhone
 ↓
HealthKit
```

Watch 本地至少保留：

```
24–72 小时
```

甚至可以更多。

这样：

- 手机不在旁边
- iPhone App 被杀
- Bluetooth 断开
- 手机没电
- Watch 暂时离线

都不会立即丢数据。

------

# 十、协议直接定义 v1

我建议：

```
HELLO
CAPABILITIES
TIME_SYNC
SYNC_REQUEST
SYNC_BATCH
SYNC_ACK
SYNC_DONE
PING
ERROR
```

Health sample：

```
sampleId
metric
value
unit
startTime
endTime
source
quality
```

协议必须支持：

```
version
sequence
cursor
ack
retry
fragmentation
capability
```

### 示例

```
iPhone
SYNC_REQUEST
cursor=1700000123456

Watch
SYNC_BATCH
seq=21
samples=[...]

iPhone
SYNC_ACK
seq=21

Watch
SYNC_BATCH
seq=22
...

Watch
SYNC_DONE
newCursor=1700000999999
```

------

# 十一、HealthKit 映射

第一版只做标准类型。

例如：

```
steps
    → HKQuantityType.stepCount

heartRate
    → HKQuantityType.heartRate

activeCalories
    → HKQuantityType.activeEnergyBurned

distance
    → HKQuantityType.distanceWalkingRunning

floors
    → HKQuantityType.flightsClimbed

spo2
    → HKQuantityType.oxygenSaturation

bodyTemperature
    → HKQuantityType.bodyTemperature
```

Workout：

```
Watch Workout
 ↓
HKWorkout
```

每条写进去的数据增加：

```
GWCSource = GalaxyWatch
```

这样我们自己的 App 可以精确识别：

> “这是 Galaxy Watch 数据，不是手机/其他 App 数据。”

------

# 十二、睡眠模块：这里我要把上一版的结论修正得更精确

### 可以做“手机上看睡眠”

**可以。**

但：

### 不应该在第一阶段声称：

> “直接读取 Samsung Health 的完整睡眠数据。”

因为 Samsung Health Data SDK 是访问 Samsung Health 数据库的 Android SDK，并不是 iOS SDK。它可以读取 SleepType，其中包括 bedtime、wake-up、actual sleep duration、sleep score 和 sleep stages，但这是 Samsung Health 数据仓库路径。[Samsung开发者](https://developer.samsung.com/health/data/guide/introduction.html?utm_source=chatgpt.com)

而 Samsung Health Sensor SDK 官方提供的是传感器数据，并不等于 Samsung Health 的睡眠算法结果。三星 FAQ 也明确说 Sensor SDK 取得的数据**不通过 Samsung Health**。[Samsung开发者](https://developer.samsung.com/health/sensor/faq.html?utm_source=chatgpt.com)

所以纯：

```
Watch → iPhone
```

模式下应该做：

> **我们的睡眠引擎。**

------

# 十三、睡眠引擎 v1

输入：

```
Accelerometer
Heart Rate
IBI
PPG（能稳定拿到再用）
SpO₂
Skin Temperature
```

输出：

```
sleepStart
sleepEnd
timeInBed
totalSleep
awake
light
deep
rem
sleepEfficiency
awakenings
```

然后计算：

```
Sleep Score
```

例如：

```
Duration             87
Efficiency            92
Fragmentation         84
Deep sleep            89
REM                   93
Resting HR            90
SpO₂ stability        97

Final = 90
```

但产品文案必须写：

> **“本应用生成的睡眠分析”**

而不是：

> “Samsung Sleep Score”。

------

# 十四、第一版睡眠算法不要太复杂

Codex 第一阶段完全可以让它实现一个**规则 + 时间序列**版本。

例如：

```
AWAKE
    movement high
    OR HR variance high

ASLEEP
    movement low
    HR stabilized

DEEP candidate
    movement very low
    HR low/stable
    HRV relatively high

REM candidate
    movement low
    HR variability higher
    micro-arousals increased
```

然后进行：

```
window smoothing
↓
minimum stage duration
↓
hysteresis
↓
merge short segments
```

不要第一版就搞机器学习。

------

# 十五、睡眠 UI

第一版直接做：

```
昨晚睡眠
────────────────

23:47
│
│   Awake
│   ━━
│
│   Light
│   ███████████
│
│   Deep
│   █████
│
│   REM
│   ███████
│
07:31
```

下面：

```
总睡眠       7h 44m
卧床         8h 09m
睡眠效率     94%

Deep         1h 25m
REM          1h 43m
Awake        28m

平均心率     56 bpm
最低心率     48 bpm

平均 SpO₂    97%
最低 SpO₂    93%

皮温变化     +0.1°C

睡眠评分     88
```

再给自然语言分析：

```
本次睡眠整体良好。

✓ 睡眠时长充足
✓ 睡眠效率良好
✓ 深睡比例正常

需要注意：
· 凌晨 03:10–03:35 出现较明显觉醒
· 后半夜心率波动略高
```

------

# 十六、通知系统

这里我建议直接支持两个 Transport：

```
ANCS
Accessory Notifications
```

### ANCS

Apple 官方的 ANCS UUID 和三组 characteristic 都是公开定义的。[Apple 开发者](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Introduction/Introduction.html?utm_source=chatgpt.com)

它适合我们的兼容基础方案：

```
iPhone
    ↓
ANCS
    ↓
Watch
```

### Accessory Notifications

这个更现代，而且可以选择：

- 全部 App
- 指定 App
- 通知内容
- 图标
- attachments
- actions

但 Apple 目前明确限制：客户安装使用该 framework 要求用户在 EU 区域并使用 EU Apple Account。[Apple 开发者](https://developer.apple.com/documentation/accessorynotifications?utm_source=chatgpt.com)

所以设计成：

```
NotificationManager
      │
      ├── ANCSProvider
      │
      └── AccessoryNotificationsProvider
```

默认 ANCS。

------

# 十七、通知范围锁定

你说只要“消息通知”，那第一版就不要碰：

```
❌ 通话
❌ 接听
❌ 拨号
❌ 短信发送
❌ iMessage 回复
❌ Notification Actions
```

只要：

```
微信
WhatsApp
Telegram
QQ
Gmail
Slack
Discord
系统通知
```

以及：

```
标题
正文
App 名称
时间
App icon（能拿则拿）
```

就够了。

------

# 十八、GitHub 代码应该怎么用

这个特别适合 Codex：

## 第一基础仓库

```
piyush140104/galaxy-health-bridge
```

MIT。

拿：

```
Wear OS GATT Server
Local Room store
Health → canonical model
iOS CoreBluetooth client
HealthKit mapping
cursor sync
```

做我们的健康 Transport 原型。

------

## 第二

```
k97/WearBridge
```

MIT。

拿：

```
ANCS
notification parser
notification state
BLE notification flow
```

做通知模块。

------

## 第三

```
CeuTryharder/GalaxyBridge
```

Apache-2.0。

参考：

```
BLE diagnostics
GATT inventory
capability probing
device compatibility
```

------

## 第四

```
abolfazlirani/WatchCardWallet
```

MIT。

只参考 NFC：

```
HCE
APDU
AID
NFC capability detection
```

------

## 第五

```
FelipeTamm123/GalaxyWatchBridge
```

这个仓库目前没有看到明确 OSS license。

所以：

> **只参考设计，不直接复制代码。**

这个需要在我们的 `THIRD_PARTY_NOTICES.md` 中注明。

------

# 十九、NFC 我建议变成一个独立模块

不要让 NFC 影响健康项目。

```
NFC/
├── Reader
├── TagParser
├── NDEF
├── ISO7816
├── MIFARE
├── Storage
├── Profile
└── Emulator
```

### 第一阶段

iPhone：

```
Scan
 ↓
Detect tag
 ↓
Read NDEF / supported info
 ↓
Save
```

Apple Core NFC 当前就支持 NDEF、ISO7816、ISO15693、FeliCa、MIFARE 等。[Apple 开发者](https://developer.apple.com/documentation/corenfc/?utm_source=chatgpt.com)

### 第二阶段

```
iPhone
 ↓ BLE
Watch
 ↓
HCE
```

Galaxy Watch8 已经有 GitHub 项目实际验证 Wear OS HCE。

但：

> **不能承诺“读取任何 NFC 卡 → 完美复制到手表”。**

尤其是：

- 银行卡
- 交通卡
- 加密门禁
- MIFARE Classic
- Secure Element

不应该设计成“卡片克隆”功能。

------

# 二十、第一版项目的核心接口

让 Codex 先写这些 protocol。

### iOS

```
protocol WatchTransport {
    func connect() async throws
    func disconnect()
    func capabilities() async throws -> WatchCapabilities
    func syncHealth(since cursor: UInt64) async throws -> [HealthSample]
    func sendCommand(_ command: WatchCommand) async throws
}

protocol HealthRepository {
    func save(_ samples: [HealthSample]) async throws
    func today() async throws -> HealthSnapshot
}

protocol SleepRepository {
    func sessions() async throws -> [SleepSession]
    func analyze(_ session: SleepSession) async throws -> SleepAnalysis
}

protocol NotificationTransport {
    func start()
    func stop()
}
```

------

# 二十一、Watch 端接口

```
interface HealthProvider {
    suspend fun capabilities(): HealthCapabilities

    fun observeHeartRate(): Flow<HeartRateSample>

    fun observeSteps(): Flow<StepSample>

    fun observeCalories(): Flow<EnergySample>

    fun observeDistance(): Flow<DistanceSample>

    fun observeSpO2(): Flow<SpO2Sample>

    fun observeSkinTemperature(): Flow<SkinTemperatureSample>
}

interface SampleStore {
    suspend fun insert(sample: HealthSample)
    suspend fun queryAfter(cursor: Long): List<HealthSample>
    suspend fun latestCursor(): Long
}

interface WatchTransport {
    suspend fun start()
    suspend fun stop()
    suspend fun send(batch: HealthBatch)
}
```

------

# 二十二、数据库设计

## Watch

```
health_samples

id
metric
value
unit
start_time
end_time
source
quality
created_at
```

## iPhone

```
sleep_sessions

id
start_time
end_time
duration
score
algorithm_version
sleep_segments

id
session_id
start_time
end_time
stage
confidence
sensor_samples

id
type
timestamp
value
unit
source
```

注意：

> iPhone 不需要长期保存所有原始传感器数据。

否则：

```
PPG
accelerometer
```

很容易把数据库撑爆。

第一版：

```
Health samples → 长期保存
Raw sensor → 短期缓存
```

------

# 二十三、最重要的兼容性设计

做：

```
WatchCapabilities
```

例如：

```
{
  "heartRate": true,
  "ibi": true,
  "steps": true,
  "calories": true,
  "distance": true,
  "floors": true,
  "spo2": true,
  "skinTemperature": true,
  "ecg": false,
  "bia": false,
  "eda": false,
  "ppg": true,
  "nfcReader": false,
  "nfcHce": true
}
```

因为三星官方明确说：

> Sensor SDK 支持的 tracker 类型会因 Galaxy Watch 型号和软件版本而变化，而且 SDK 提供 capability check API。[Samsung开发者](https://developer.samsung.com/health/sensor/faq.html?utm_source=chatgpt.com)

所以这个必须是核心架构，不是 UI 小功能。

------

# 二十四、第一阶段不要直接上所有传感器

我建议 Codex 按这个顺序开发。

## Sprint 0：工程骨架

```
iOS project
Wear OS project
Shared protocol
CI
Lint
Tests
```

完成标准：

```
iOS builds
Watch builds
Tests pass
```

------

## Sprint 1：真正的 BLE

```
Watch advertising
iPhone scanning
connect
discover service
pair/bond
disconnect
reconnect
```

**这是整个项目第一关。**

没有这个，就暂时不要写 Dashboard。

------

## Sprint 2：最基础健康

只做：

```
Heart Rate
IBI
Steps
Calories
Distance
Floors
Battery
```

建立：

```
Watch DB
Cursor
Sync
ACK
Resume
```

------

## Sprint 3：HealthKit

把：

```
Watch
 ↓
iPhone
 ↓
HealthKit
```

彻底打通。

此时项目已经可以作为一个“可用版本”。

------

## Sprint 4：高级健康

加：

```
SpO₂
Skin Temperature
Workout
Respiratory Rate
HRV
```

------

## Sprint 5：睡眠

第一阶段：

```
sleep session
sleep duration
sleep timeline
HR
SpO₂
temperature
```

第二阶段：

```
Awake
Light
Deep
REM
Sleep Score
```

------

## Sprint 6：通知

```
ANCS
App filtering
Message display
```

------

## Sprint 7：NFC

```
iPhone Core NFC
Tag parsing
NDEF
保存
Watch capability
HCE
```

------

# 二十五、我建议的最终技术栈表

| 层              | 技术                                           |
| --------------- | ---------------------------------------------- |
| iOS UI          | SwiftUI                                        |
| iOS language    | Swift 6.2.x                                    |
| iOS IDE         | Xcode 26.3                                     |
| iOS minimum     | iOS 17                                         |
| BLE             | CoreBluetooth                                  |
| Health          | HealthKit                                      |
| NFC             | Core NFC                                       |
| Persistence     | SwiftData                                      |
| Async           | Swift Concurrency                              |
| Watch language  | Kotlin 2.4.20                                  |
| Watch UI        | Jetpack Compose for Wear OS Material 3         |
| Wear Compose    | 1.7.1                                          |
| Health Services | `androidx.health:health-services-client:1.1.0` |
| Samsung sensors | Samsung Health Sensor SDK 1.4.1                |
| BLE Watch       | BluetoothGattServer                            |
| Watch DB        | Room                                           |
| Serialization   | kotlinx.serialization                          |
| Concurrency     | Kotlin Coroutines + Flow                       |
| Watch OS target | Wear OS 3+                                     |
| Android API     | compile/target 36                              |
| JDK             | 17                                             |
| Build           | Gradle Kotlin DSL                              |
| Protocol        | 自定义 versioned BLE protocol                  |
| Notification    | ANCS first, Accessory Notifications optional   |
| NFC Watch       | Android NFC/HCE                                |
| Tests iOS       | Swift Testing + XCTest                         |
| Tests Android   | JUnit + AndroidX Test                          |
| CI              | GitHub Actions                                 |

这些版本里，Xcode 26.3/Swift 6.2.3、Wear Compose 1.7.1、Health Services 1.1.0、Samsung Sensor SDK 1.4.1 都是我按 **2026 年 10 月 8 日**当前官方资料核过的版本。[Apple 开发者](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes?changes=l_4&utm_source=chatgpt.com)

------

# 二十六、Codex 的开发原则也要提前定下来

这个很重要。

让 Codex 遵守：

```
1. 不猜三星私有协议
2. 不使用 iOS 私有 API
3. 不依赖 Wear Data Layer 与 iPhone 通信
4. 不把 BLE callback 直接塞进 SwiftUI
5. 不让 UI 直接访问数据库
6. 不让 UI 直接访问 Bluetooth
7. 所有设备能力必须 capability-driven
8. 所有健康数据必须有 source 和 timestamp
9. 所有 BLE 传输必须可恢复
10. Watch 离线必须不会丢数据
11. 高级 Samsung SDK 必须可选
12. Raw sensor 数据不能无限落库
13. 睡眠算法必须带 algorithmVersion
14. 所有逆向实验必须独立于正式协议
15. 不复制无许可证仓库的代码
```

这个规范非常适合 vibe coding，因为它能防止 Codex 逐渐把代码“写歪”。

------

# 二十七、我建议第一版甚至不要做“AI”

睡眠分析第一版：

```
规则
+
统计
+
时间序列
```

先把：

```
数据采集
→ 数据质量
→ 同步稳定性
→ 睡眠分段
```

做准确。

以后再增加：

```
Core ML
```

做个性化睡眠模型。

否则一开始 Codex 很容易变成：

> “先给你生成一个很漂亮的 AI Sleep Score，但原始数据都没传对。”

这对这种项目是最危险的。

------

# 二十八、最终 MVP

最后把它压缩成一句开发目标：

```
Galaxy Watch
      ↓ BLE
iPhone Galaxy Companion
      │
      ├── Health
      │    ├── Steps
      │    ├── HR
      │    ├── IBI / HRV
      │    ├── Calories
      │    ├── Distance
      │    ├── Floors
      │    ├── SpO₂
      │    └── Skin Temp
      │
      ├── Sleep
      │    ├── Sleep Session
      │    ├── Stages
      │    ├── HR
      │    ├── SpO₂
      │    ├── Temp
      │    └── Sleep Analysis
      │
      ├── Notifications
      │    └── iPhone → Watch
      │
      ├── HealthKit
      │
      └── NFC Lab
```

**这个版本我认为非常适合直接开始 vibe coding。**

而且有一个关键优势：现有 GitHub 项目已经把健康 BLE、ANCS、BLE diagnostics、NFC HCE 各自拆开验证过，我们不是从白纸开始；其中 `galaxy-health-bridge` 本身就是 MIT，当前已有 Watch→iPhone→HealthKit 基础实现，`WearBridge` 也是 MIT 的 ANCS 项目。[galaxy-health-bridge](https://github.com/piyush140104/galaxy-health-bridge?utm_source=chatgpt.com) [WearBridge](https://github.com/k97/WearBridge?utm_source=chatgpt.com)

接下来最适合直接给 Codex 的不是一句“帮我开发这个 App”，而是下面这份**首轮初始化指令**：

你现在负责开发一个名为 `GalaxyWatchCompanion` 的 iOS + Wear OS monorepo 项目。

## 产品目标

开发一个第三方 Galaxy Watch → iPhone companion app，核心能力：

1. Galaxy Watch 与 iPhone 通过 BLE/GATT 连接
2. 从 Galaxy Watch 获取健康数据并同步到 iPhone
3. 健康数据写入 Apple Health / HealthKit
4. iPhone 消息通知转发到 Galaxy Watch
5. iPhone 查看睡眠数据和生成睡眠分析报告
6. 尽可能支持较多 Galaxy Watch 健康传感器
7. NFC 作为独立实验模块：iPhone NFC Reader + Watch HCE capability detection

不实现：

- 电话
- 短信发送/回复
- eSIM
- 支付
- Samsung Account
- Galaxy Store
- 固件 OTA
- 查找手表
- Samsung Health 云端历史数据
- 完整 Galaxy Wearable 设置
- 三星云备份

## 技术约束

### iOS

- Swift 6.2.x
- SwiftUI
- Observation
- Swift Concurrency
- CoreBluetooth
- HealthKit
- CoreNFC
- SwiftData
- minimum iOS 17
- Xcode 26.3

### Wear OS

- Kotlin 2.4.20
- Jetpack Compose for Wear OS Material 3
- Wear Compose 1.7.1
- `androidx.health:health-services-client:1.1.0`
- Samsung Health Sensor SDK 1.4.1，必须设计为可选 provider
- Room
- kotlinx.serialization
- Kotlin Coroutines / Flow
- BluetoothGattServer
- compileSdk 36
- targetSdk 36
- minSdk 30
- JDK 17

## 通信原则

绝对不要使用 Wear OS Data Layer 与 iPhone 通信。

主通信必须是：

Galaxy Watch BLE GATT Server
↕
iPhone CoreBluetooth Central

健康数据：

Watch Sensor
→ Watch Local DB
→ BLE Sync
→ iPhone
→ HealthKit

通知：

iPhone ANCS
→ Watch BLE GATT Client

Accessory Notifications 可作为未来 iOS 26+ 可选 provider，但 ANCS 是主方案。

## 架构原则

必须严格分层：

UI
→ Feature/ViewModel
→ UseCase
→ Repository
→ Transport / Database

UI 不得直接访问 CoreBluetooth。

UI 不得直接访问 SwiftData。

所有 BLE callback 必须转换成业务事件。

Bluetooth 层不得暴露 CBPeripheral 等 framework 类型给业务层。

业务层只能看到 Sendable/value-type models。

## Watch capabilities

建立统一 capability model：

- heartRate
- ibi
- steps
- calories
- distance
- floors
- spo2
- skinTemperature
- respiratoryRate
- ppg
- accelerometer
- eda
- bia
- mfBia
- ecg
- nfcReader
- nfcHce

所有 UI 和功能都必须根据 capability 动态启用。

## BLE protocol v1

定义：

- HELLO
- CAPABILITIES
- TIME_SYNC
- SYNC_REQUEST
- SYNC_BATCH
- SYNC_ACK
- SYNC_DONE
- PING
- ERROR

协议必须支持：

- protocol version
- sequence
- cursor
- ACK
- retry
- fragmentation
- resume
- capability negotiation

健康 sample 至少包含：

- sampleId
- metric
- value
- unit
- startTime
- endTime
- source
- quality

## Watch storage

Watch 使用 Room 保存健康 sample。

至少保证手机暂时不连接时健康数据不会立即丢失。

Sync 必须是 cursor-based incremental sync。

## Health providers

定义：

```
HealthProvider
```

至少实现：

```
WearHealthServicesProvider
```

并预留：

```
SamsungHealthSensorProvider
```

Samsung Sensor SDK 不得成为基础架构的硬依赖。

## iOS HealthKit

至少建立这些映射：

- stepCount
- heartRate
- activeEnergyBurned
- distanceWalkingRunning
- flightsClimbed
- oxygenSaturation
- bodyTemperature
- HKWorkout

写入的 sample metadata 增加：

```
GWCSource = GalaxyWatch
```

## Sleep

不要依赖 Samsung Health 云端数据。

纯 Watch → iPhone 模式使用本地睡眠分析。

第一版：

- sleep start
- sleep end
- total sleep
- time in bed
- efficiency
- awake
- light
- deep
- REM
- awakenings
- heart rate
- HRV / IBI
- SpO2
- skin temperature
- sleep score

睡眠算法必须有：

```
algorithmVersion
```

不要宣称复制 Samsung Sleep Score。

## Notifications

第一版只实现：

- 微信
- WhatsApp
- Telegram
- QQ
- Gmail
- Slack
- Discord
- 一般 iOS notifications

只需要：

- app name
- title
- body
- timestamp
- optional icon

不实现：

- call
- SMS sending
- iMessage reply
- action reply

## NFC

NFC 做成独立 module。

iPhone：

- NFCNDEFReaderSession
- NFCTagReaderSession
- NDEF parsing
- ISO7816 / MIFARE / FeliCa / ISO15693 detection

Watch：

- NFC capability detection
- HCE capability detection
- future emulator/profile support

不要实现银行卡、交通卡、加密门禁卡的复制功能。

## Repository reuse

可以参考：

- `piyush140104/galaxy-health-bridge`
- `k97/WearBridge`
- `CeuTryharder/GalaxyBridge`
- `abolfazlirani/WatchCardWallet`

MIT / Apache-2.0 licensed code 可在遵守许可证前提下使用。

对于没有明确开源许可证的仓库，只允许参考架构和设计，不复制代码。

## 开发顺序

第一阶段只做：

1. repo structure
2. iOS app bootstrap
3. Wear OS app bootstrap
4. shared protocol definitions
5. BLE advertiser
6. iPhone BLE scanner
7. GATT discovery
8. connect / disconnect / reconnect
9. capability exchange
10. test fake watch
11. unit tests
12. CI

第一阶段完成前，不要开发 Dashboard、睡眠 UI、NFC UI 等复杂功能。

## 代码质量

必须：

- Swift strict concurrency
- Kotlin structured concurrency
- typed errors
- no force unwrap except explicitly justified
- no massive ViewModel
- no global mutable singleton state
- test protocol codec
- test cursor sync
- test duplicate handling
- test reconnect
- test partial BLE packets
- test malformed packet
- test HealthKit mapping
- test sleep segmentation with fixtures

先建立稳定架构，然后再逐阶段实现功能。

每完成一个阶段，都必须：

1. build
2. unit test
3. static analysis
4. 更新 docs
5. 更新 capability matrix
6. 保证已有功能不回归

这份指令可以直接作为 Codex 的第一轮项目约束。之后就让它**先只做 Sprint 0 + Sprint 1，千万别一开始让它把所有页面都生成出来**。对于这种 BLE + Wear OS + HealthKit 项目，先把真实手表链路打通，后面再让 Codex 快速堆 UI，成功率会高很多。