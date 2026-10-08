我重新审了一遍三星官方 SDK、Apple 的 BLE/HealthKit/通知能力，以及现在 GitHub 上的相关项目。下面这版可以直接作为项目立项依据。

# 最终目标

我们把软件定义成：

> **iPhone 上的 Galaxy Watch Companion：负责连接手表、同步健康数据、接收 iPhone 消息通知，并在手机上查看睡眠与健康分析。**

明确不做：

- 找手表
- 手表系统设置
- eSIM
- 支付
- 电话
- 短信发送/回复
- 三星账号
- Galaxy Store
- 固件 OTA
- 三星云端历史数据同步
- 完整复制 Galaxy Wearable

这样以后，项目的核心就只剩下：

```
1. 连接 Galaxy Watch
2. 健康数据 → iPhone
3. iPhone 通知 → Galaxy Watch
4. 手机查看健康/睡眠
5. 尽可能多地利用 Galaxy Watch 传感器
6. NFC 实验性支持
```

**这个版本我认为值得做。**

------

# 一、最核心的“连接”是可以做的

三星官方明确不支持 Galaxy Watch4 及之后的 Wear OS Galaxy Watch 与 iPhone 官方配对，但这不代表第三方 App 完全不能通信。

我们的思路不是：

```
iPhone
 ↓
Galaxy Wearable
 ↓
Galaxy Watch
```

而是：

```
iPhone
 ↓ CoreBluetooth
BLE / GATT
 ↓
我们自己的 Wear OS App
 ↓
Galaxy Watch
```

GitHub 上已经有实际项目采用这个模式，而且 `galaxy-health-bridge` 已经把：

> Galaxy Watch → BLE → iPhone → HealthKit

这个完整方向做出来了。项目目前直接支持步数、活动卡路里、距离、心率、楼层等，并且代码中采用 Watch 端本地缓存 + cursor 增量同步，思路很适合我们。[piyush140104/galaxy-health-bridge](https://github.com/piyush140104/galaxy-health-bridge?utm_source=chatgpt.com)

所以：

**连接这一关不是理论可行，而是已有开源实现可以直接作为技术起点。**

------

# 二、健康同步：这部分反而是最有把握的

三星目前的 **Samsung Health Sensor SDK** 支持 Galaxy Watch4 及以后 Wear OS Galaxy Watch，而且可以从手表上的 App 获取很多原始/处理后的健康传感器数据。三星官方列出的能力包括：

- Accelerometer
- BIA
- MF-BIA
- ECG
- EDA
- Heart Rate
- IBI
- PPG
- Skin Temperature
- SpO₂
- Sweat Loss

而 Wear OS 自己的 Health Services 还能提供：

- Heart rate
- Steps
- Distance
- Calories
- Elevation
- Floors
- Speed
- Pace
- Exercise 等。[Samsung开发者](https://developer.samsung.com/health/sensor/guide/introduction.html?utm_source=chatgpt.com)

所以你说的：

> “传感器尽量多，但是复杂的可以不要”

这个策略非常对。

------

# 三、我建议第一版实际接这些

不要一上来把 ECG、BIA、原始 PPG 全部搬回来。

第一版先做这些：

| 数据       | 建议                      |
| ---------- | ------------------------- |
| 步数       | ✅ 必做                    |
| 心率       | ✅ 必做                    |
| IBI        | ✅ 做                      |
| 活动卡路里 | ✅ 必做                    |
| 距离       | ✅ 必做                    |
| 楼层       | ✅ 做                      |
| 运动记录   | ✅ 做                      |
| SpO₂       | ✅ 做                      |
| 睡眠       | ✅ 做                      |
| 睡眠阶段   | ✅ 尝试                    |
| 皮肤温度   | ✅ 做                      |
| HRV        | ✅ 做，必要时自己从 IBI 算 |
| 呼吸频率   | ✅ 尽量做                  |
| 加速度     | ✅ 做为底层数据            |
| EDA        | 🟡 后期                    |
| BIA/体脂   | 🟡 后期                    |
| ECG        | 🟡 后期                    |
| 原始 PPG   | 🟡 后期                    |

这已经比绝大多数普通智能手表 App 的数据丰富了。

三星官方也明确支持连续读取部分传感器，其中加速度、心率、PPG、皮肤温度属于连续 tracker；不同型号的数据能力和频率会不同，所以软件需要做 capability detection，而不能假设所有 Watch 都一样。[Samsung开发者](https://developer.samsung.com/health/sensor/guide/data-specifications.html?utm_source=chatgpt.com)

------

# 四、Apple Health：非常适合做我们的“总出口”

这个部分没有必要绕。

直接：

```
Galaxy Watch
     ↓
Wear OS Companion
     ↓ BLE
iPhone App
     ↓
HealthKit
     ↓
Apple 健康
```

Apple 官方把 HealthKit 定义为 iPhone 上健康与健身数据的中心存储库，App 可以在用户授权下读取和写入。[Apple 开发者](https://developer.apple.com/documentation/Xcode/configuring-healthkit-access?changes=la_3_8%2Cla_3_8&language=objc%2Cobjc&utm_source=chatgpt.com)

所以第一版我建议：

> **所有标准健康指标优先写入 Apple Health。**

这样不仅你自己的 App 能看，Apple Health 和其他授权的第三方健康 App 也能使用。

------

# 五、微信其实也不需要我们直接“接微信”

这是一个很重要的简化。

你的需求说：

> “写入 Apple Health 或者微信”

我的建议是：

**不要设计 Galaxy Watch → 微信。**

设计：

```
Galaxy Watch
    ↓
我们的 App
    ↓
Apple Health
    ↓
微信
```

这个路径本身在 iOS 生态里是成立的。

例如华为官方对 iOS 的说明就是：

```
穿戴设备
 ↓
华为运动健康
 ↓
Apple Health
 ↓
微信
```

也就是说，**微信可以把 Apple Health 当作中间层读取运动数据**。[华为消费者业务](https://consumer.huawei.com/cn/support/content/zh-cn15816399/?utm_source=chatgpt.com)

App Store 上也能看到已有健康类 App 支持“设备 → Apple Health”，以及部分产品通过自身服务再与微信运动互通。[App Store](https://apps.apple.com/cn/app/即米运动健康-runmefit/id6523415658?utm_source=chatgpt.com)

所以我们的最佳策略是：

> **HealthKit 是标准出口，微信作为 HealthKit 下游应用使用。**

这样我们根本不用依赖微信私有接口。

------

# 六、睡眠：这里需要把“能不能看”和“能不能复制三星算法”分开

你的要求其实非常适合我们：

> 只需要手机查看睡眠数据和分析报告，不需要同步、不需要备份、不需要三星服务器历史数据。

### 结论：

**可以做。**

但要分两种层次。

------

## 第一层：直接读取/记录睡眠基础信息

可以做：

```
睡眠开始
睡眠结束
总睡眠
清醒时间
卧床时间
入睡时间
起床时间
心率
皮肤温度
血氧
活动
```

Wear OS Health Services 本身提供睡眠/活动相关的能力，而且后台 passive monitoring 可以独立于你的 UI 持续运行。[Android Developers](https://developer.android.com/reference/androidx/health/services/client/data/UserActivityState?utm_source=chatgpt.com)

------

## 第二层：睡眠阶段

这里不能简单地说：

> “三星已经有睡眠阶段，所以我们直接 API 拿出来。”

因为三星的 **Samsung Health Data SDK** 确实能读取：

- 睡眠时长
- 入睡/起床时间
- Sleep Score
- Sleep Session
- Light
- Deep
- REM
- associated SpO₂
- associated Skin Temperature

但这个 SDK 的目标是 **Android 手机上的 Samsung Health 数据仓库**，不是 iOS。[Samsung开发者](https://developer.samsung.com/health/data/overview.html?utm_source=chatgpt.com)

换句话说：

```
Samsung Health Data SDK
        ↓
Samsung Health 数据库
        ↓
Android
```

这一条不属于我们的“纯 iPhone 模式”。

------

# 七、但是我们可以自己做一套“睡眠分析”

这其实很有意思。

三星的 Sensor SDK 可以提供：

- 心率
- IBI
- PPG
- Accelerometer
- Skin temperature
- SpO₂

这些数据足够我们建立一个：

```
Galaxy Watch
     ↓
Raw / processed sensor data
     ↓
Sleep Engine
     ↓
iPhone
     ↓
Sleep Report
```

然后手机直接生成：

### 睡眠报告

例如：

```
昨晚睡眠
────────────────

总睡眠       7h 42m
卧床时间     8h 11m
睡眠效率     94%

Awake        29m
Light        4h 03m
Deep         1h 28m
REM          2h 11m

入睡         23:48
起床         07:30

平均心率     57 bpm
最低心率     49 bpm

SpO₂ 平均    97%
最低         93%

皮肤温度    +0.1°C
```

再进一步：

```
睡眠评分 87

✓ 入睡时间正常
✓ 深睡比例良好
✓ REM 正常

⚠ 夜间有 4 次短暂觉醒
⚠ 01:30–02:10 心率偏高
```

这非常符合你的需求。

------

# 八、但我不建议承诺“完全复刻三星睡眠算法”

这一点我会直接卡死。

因为：

> **三星 Sleep Score / Sleep Coaching 等不是简单的公开传感器公式。**

三星自己的 SleepType 包含 sleep score、sleep duration、session、stage，而且 Samsung Health 还会把睡眠期间的 SpO₂ 和皮肤温度作为关联数据。[Samsung开发者](https://developer.samsung.com/health/data/api-reference/-shd/com.samsung.android.sdk.health.data.request/-data-type/-sleep-type/index.html?utm_source=chatgpt.com)

所以我们可以做：

> **自己的睡眠分析**

而不是宣传：

> **“这是三星 Sleep Score 的复制品。”**

这样技术上更干净，也更容易长期维护。

------

# 九、最推荐的睡眠产品逻辑

我建议第一版只做：

### 睡眠基础

- 睡眠开始
- 睡眠结束
- 总时长
- 卧床时间
- 睡眠效率
- 清醒时间

### 睡眠阶段

- Awake
- Light
- Deep
- REM

### 睡眠期间关联数据

- Heart Rate
- HRV/IBI
- SpO₂
- Skin Temperature
- Movement

### 分析

- Deep %
- REM %
- Awake %
- Sleep Efficiency
- Resting HR
- HRV trend
- SpO₂ 波动
- 温度异常
- 夜间觉醒次数

已经完全够用了。

------

# 十、通知：现在可以直接把需求做得非常简单

你说：

> 只要消息通知，不要电话/短信。

这反而特别适合我们。

目标：

```
iPhone
 ↓
WhatsApp / WeChat / Telegram / QQ / Gmail 等
 ↓
iOS Notification Center
 ↓
Bluetooth
 ↓
Galaxy Watch
```

Apple 原生有 ANCS（Apple Notification Center Service），可以让 BLE accessory 接收到 iPhone 通知，并获得通知的内容。官方协议定义了：

- Notification Source
- Control Point
- Data Source

可以收到：

- 新通知
- 通知更新
- 通知删除
- 标题
- 正文
- App 信息等。[Apple 开发者](https://developer.apple.com/library/archive/documentation/CoreBluetooth/Reference/AppleNotificationCenterServiceSpecification/Specification/Specification.html?utm_source=chatgpt.com)

GitHub 上现有的 `WatchBridge` 就已经沿这条路线做了：

- iMessage
- WhatsApp
- Telegram
- Slack
- 邮件
- Calendar
- 通知
- 来电提醒

所以我们直接把“电话功能”等砍掉即可。[rajtiwariee/watchbridge](https://github.com/rajtiwariee/watchbridge?utm_source=chatgpt.com)

------

# 十一、还有一个更现代的新路线：Accessory Notifications

Apple 现在又提供了 **Accessory Notifications**。

它允许一个配套 App 请求 iPhone 把系统通知转给配件，而且可以：

- 全部 App
- 指定 App
- 只转某些 App
- 通知内容
- 图标
- attachments
- actions

Apple 还提供了加密传输和 accessory transport extension。[Apple 开发者](https://developer.apple.com/documentation/accessorynotifications?utm_source=chatgpt.com)

这条路线值得我们研究。

但目前 Apple 文档明确注明：

> Accessory Notifications 的客户安装限制在欧盟地区。

所以为了兼容性，我会把：

### 主方案

**ANCS**

### 新方案

**Accessory Notifications**

分开。

------

# 十二、NFC：这个需求需要特别说清楚

你说：

> “要是能录制 NFC 最好了。”

这个词实际上对应三个完全不同的技术目标。

------

## A. 读取 NFC 标签

例如：

```
NFC Tag
 ↓
Galaxy Watch
 ↓
读取 NDEF / UID
 ↓
我们的 App
```

Android 官方 NFC API 支持：

- Reader mode
- NDEF
- NFC-A/B
- 其他 tag technology
- 原始 NFC 通讯。[Android Developers](https://developer.android.com/develop/connectivity/nfc/nfc?utm_source=chatgpt.com)

**理论上可以。**

但是 Galaxy Watch 最大的问题是：

> **有没有把 NFC Reader 能力暴露给第三方 App。**

这个必须按具体手表验证。

------

# 十三、非常有意思的是：Galaxy Watch 的 NFC“读”和“模拟”可以是两回事

GitHub 上我找到一个很有价值的项目：

### `abolfazlirani/WatchCardWallet`

它就是专门做：

> **Galaxy Watch8 + Wear OS + NFC HCE**

也就是让手表作为 NFC 卡片被外部读卡器读取。

项目甚至已经在实际 Galaxy Watch8 上验证了：

```
HCE = true
```

但是：

```
android.hardware.nfc = false
```

也就是：

> **这个 Watch8 可以模拟 NFC 卡，但不支持 NFC Reader。**

因此：

```
Galaxy Watch
      │
      ├── NFC Card Emulation  ✅
      │
      └── NFC Reader          ❌/看型号
```

这件事非常重要。[WatchCardWallet on GitHub](https://github.com/abolfazlirani/WatchCardWallet?utm_source=chatgpt.com)

------

# 十四、所以“录制 NFC”我建议定义成两个功能

## NFC Reader

尝试做到：

```
Scan NFC
↓
Tag type
UID
NDEF
raw data（允许的情况下）
↓
保存到本地
```

这个值得做。

------

## NFC Emulator

可以做：

```
Saved profile
↓
Galaxy Watch
↓
HCE
↓
NFC Reader
```

`WatchCardWallet` 已经证明 Galaxy Watch8 上 HCE 可以实现。[WatchCardWallet on GitHub](https://github.com/abolfazlirani/WatchCardWallet?utm_source=chatgpt.com)

------

# 十五、但是“扫描门禁卡 → 一键复制成手表门禁卡”不要作为核心承诺

因为很多 NFC 卡：

- 不是 NDEF
- 有加密
- 依赖特定协议
- UID/安全区不能简单复制
- 需要 Secure Element
- MIFARE/交通卡/银行卡并不是“读出一串 hex 然后 HCE 播回去”这么简单

`WatchCardWallet` 本身也明确把：

- 固定 UID
- MIFARE Classic
- NTAG
- DESFire
- 银行卡
- 交通卡

等列为不可直接复制/模拟的范围。[WatchCardWallet on GitHub](https://github.com/abolfazlirani/WatchCardWallet?utm_source=chatgpt.com)

所以我们的 NFC 功能应该叫：

> **NFC Lab / NFC Reader / NFC Emulator**

而不是：

> NFC 卡复制器。

这样产品定位也更干净。

------

# 十六、最终的软件功能，我建议锁成这样

## iPhone App

### 首页

```
Galaxy Watch 7
● 已连接

电量 82%

今日
────────────
8,642     步数
5.9 km    距离
482 kcal  活动消耗
63 bpm    当前心率

睡眠
7h 42m
87 分

SpO₂
97%

[同步]
```

### Health

```
Steps
Heart Rate
HRV
Calories
Distance
Floors
SpO₂
Skin Temperature
Respiratory Rate
Workouts
Sleep
```

### Sleep

```
昨晚

23:48 ───────── 07:30

Awake
Light
Deep
REM

睡眠评分
87

睡眠效率
94%

HR
HRV
SpO₂
Temperature

AI / Rule-based analysis
```

### Notifications

```
WhatsApp
WeChat
Telegram
Gmail
Messages
...
```

可以让用户勾选要转给手表的 App。

### NFC Lab

```
NFC
────────

Scan Tag

Last scanned:
NFC-A
UID: XXXXXXXX

NDEF
Text:
...

[ Save ]

[ Test Emulator ]
```

------

# 十七、整个系统结构，我现在建议非常明确

```
                         iPhone
┌─────────────────────────────────────────┐
│                                         │
│   SwiftUI App                           │
│       │                                 │
│       ├── Dashboard                     │
│       ├── Health                        │
│       ├── Sleep                         │
│       ├── Notifications                 │
│       ├── NFC Lab                       │
│       └── Diagnostics                   │
│              │                          │
│              ▼                          │
│        Galaxy Transport Layer           │
│              │                          │
│       CoreBluetooth / ANCS              │
│              │                          │
│              ▼                          │
└──────────────┼──────────────────────────┘
               │ BLE
               │
┌──────────────▼──────────────────────────┐
│                Galaxy Watch             │
│                                         │
│        Our Wear OS Companion             │
│                 │                       │
│       ┌─────────┼──────────┐            │
│       │         │          │            │
│       ▼         ▼          ▼            │
│ Health Services Sensor SDK   NFC        │
│       │         │                       │
│       └────┬────┘                       │
│            ▼                            │
│       Local Sample DB                  │
│            │                            │
│            ▼                            │
│       BLE GATT Server                  │
│                                         │
└─────────────────────────────────────────┘
```

------

# 十八、数据传输不要直接把所有东西塞成 JSON

现在已有的 `galaxy-health-bridge` 是 JSON frame，作为 MVP 没问题。它已经把 cursor、sample store、HealthKit dedupe 等基础东西做好了。[galaxy-health-bridge](https://github.com/piyush140104/galaxy-health-bridge?utm_source=chatgpt.com)

但我们的正式版，我建议直接改成：

```
Protocol v1

HELLO
CAPABILITIES
TIME_SYNC
HEALTH_BATCH
HEALTH_ACK
SLEEP_SESSION
NOTIFICATION
NFC
PING
ERROR
```

再加：

- sequence
- ACK
- retry
- resume
- cursor
- protocol version
- capability negotiation
- encryption

这样以后 Watch4 → Watch9 都能在一个协议里管理。

------

# 十九、必须做“能力矩阵”

因为 Samsung 官方已经明确提醒：

> Wear OS 设备的底层传感器和支持的数据类型存在差异，应用应该根据设备能力动态显示/隐藏高级指标。[Android Developers](https://developer.android.com/health-and-fitness/health-services/compatibility?authuser=09&utm_source=chatgpt.com)

所以 App 里面应该有：

```
Galaxy Watch 7

Health:
✓ Step
✓ HR
✓ IBI
✓ SpO₂
✓ Skin Temp
✓ HRV
✓ Sleep

Advanced:
✓ ECG
? BIA
? EDA

NFC:
✓ HCE
? Reader
```

而不是：

```
所有手表强行显示一样的菜单。
```

------

# 二十、唯一需要提前注意的商业/发布问题

三星的 **Samsung Health Sensor SDK** 不是“下载 jar 后随便发给用户”这么简单。

三星官方现在要求：

> 使用该 SDK 的 App 在分发之前需要提交 partner request；通过审核之后，App 的 package name / SHA-256 等信息会被注册，否则 Sensor SDK 的 App 只能在开发者模式工作。[Samsung开发者](https://developer.samsung.com/health/sensor/process.html?utm_source=chatgpt.com)

这个非常重要。

因此：

### 基础健康

可以优先用：

**Wear OS Health Services**

### 高级健康

再接：

**Samsung Health Sensor SDK**

这样项目不会从第一天就被 Samsung SDK partner 审核卡死。

------

# 二十一、所以我现在给这个项目的评级

按照你现在的需求：

| 项目                       | 可行性                   |
| -------------------------- | ------------------------ |
| Galaxy Watch ↔ iPhone 连接 | **★★★★★**                |
| 步数                       | **★★★★★**                |
| 心率                       | **★★★★★**                |
| IBI / HRV                  | **★★★★★**                |
| 卡路里                     | **★★★★★**                |
| 距离                       | **★★★★★**                |
| 楼层                       | **★★★★☆**                |
| SpO₂                       | **★★★★☆**                |
| 皮肤温度                   | **★★★★☆**                |
| Workout                    | **★★★★☆**                |
| 睡眠总时长                 | **★★★★☆**                |
| 睡眠阶段                   | **★★★☆☆～★★★★☆**         |
| 自己做睡眠分析             | **★★★★☆**                |
| Apple Health               | **★★★★★**                |
| 微信运动间接同步           | **★★★★☆**                |
| iPhone 消息 → Watch        | **★★★★☆**                |
| 后台自动同步               | **★★★☆☆**                |
| NFC 读取                   | **★★☆☆☆～★★★★☆**，看型号 |
| NFC HCE                    | **★★★★☆**，部分型号      |
| NFC “复制门禁卡”           | **★☆☆☆☆**                |
| Samsung Health 云历史      | **不做**                 |
| Galaxy Wearable 全功能     | **不做**                 |

------

# 二十二、最终我建议我们把 MVP 定成这 8 个东西

不要再膨胀。

### MVP v0.1

**① Galaxy Watch 连接**

```
扫描 → 配对 → 连接 → 自动重连
```

**② 健康同步**

```
Steps
HR
IBI/HRV
Calories
Distance
Floors
SpO₂
Skin Temp
```

**③ HealthKit**

全部规范化写入 Apple Health。

**④ 微信**

不直接接微信，走：

```
HealthKit → 微信
```

**⑤ 睡眠**

```
睡眠时间
Awake
Light
Deep
REM
HR
HRV
SpO₂
Temperature
```

然后自己生成睡眠报告。

**⑥ 消息通知**

```
微信
WhatsApp
Telegram
QQ
Gmail
其他 iOS 通知
```

**⑦ NFC Lab**

先做到：

```
NFC Reader
NDEF
UID
保存
HCE 实验
```

**⑧ Diagnostics**

显示：

```
Watch Model
Wear OS
One UI Watch
Firmware
BLE
MTU
Capabilities
Health SDK
NFC Capability
```

------

# 二十三、而 GitHub 基础，我现在会这么选

### 健康同步核心

**第一选择：**

[piyush140104/galaxy-health-bridge](https://github.com/piyush140104/galaxy-health-bridge?utm_source=chatgpt.com)

因为它已经有：

- Watch App
- iOS App
- GATT
- BLE
- Local DB
- Cursor sync
- HealthKit
- tests

**这个可以直接作为健康传输地基。**

------

### 通知

[rajtiwariee/watchbridge](https://github.com/rajtiwariee/watchbridge?utm_source=chatgpt.com)

重点参考 ANCS 方案。

------

### BLE/工程架构

[FelipeTamm123/GalaxyWatchBridge](https://github.com/FelipeTamm123/GalaxyWatchBridge?utm_source=chatgpt.com)

重点参考：

- CoreBluetooth
- async/await
- GATT
- framing
- state machine
- diagnostics

------

### 协议探测

[CeuTryharder/GalaxyBridge](https://github.com/CeuTryharder/GalaxyBridge?utm_source=chatgpt.com)

重点参考：

- GATT inventory
- capability detection
- diagnostics
- physical-device testing

------

### NFC

[abolfazlirani/WatchCardWallet](https://github.com/abolfazlirani/WatchCardWallet?utm_source=chatgpt.com)

这个对我们的 NFC 设计特别有参考意义，因为它已经在实际 Galaxy Watch8 上验证了 Wear OS HCE，而且清楚区分了 HCE 与 NFC Reader 能力。

------

# 最终结论

现在这个项目我会直接给：

> **值得开发：9/10**

而且你现在这个需求比最初那个“做一个 Samsung Health + Galaxy Wearable 的 iOS 完整替代品”现实得多。

真正的核心产品可以非常明确：

```
       Galaxy Watch
             │
             │ BLE
             ▼
       ┌─────────────┐
       │ iPhone App  │
       ├─────────────┤
       │ 连接        │
       │ 健康        │
       │ 睡眠        │
       │ 通知        │
       │ NFC         │
       └──────┬──────┘
              │
       ┌──────┴──────┐
       ▼             ▼
   Apple Health     微信
```

其中最有价值的其实是：

**“Galaxy Watch + iPhone + Apple Health”**

因为三星在 iOS 上留下的正好是这个空白。

而你新增的**手机睡眠分析**，我建议直接做成我们的特色功能，而不是试图恢复三星服务器上的 Sleep 页面：

> **手表负责采集，iPhone 负责分析。**

这样不需要三星云、不需要 Android 手机，也不需要历史备份，完全符合你现在的需求。

NFC 则作为 **实验性功能** 放进架构，从一开始预留接口；能读的手表就开 Reader，只有 HCE 的手表就只开 Emulator，避免把整个项目绑在 NFC 上。

下一阶段已经可以不再继续做泛泛的调研了，而是直接进入**工程设计**：我建议下一份文档就做成“**v0.1 技术规格书**”，把 Watch 端需要调用的每一个 SDK、每个健康指标对应哪个 API、BLE 协议怎么设计、HealthKit 每项数据怎么映射、睡眠算法第一版怎么做，以及 GitHub 那几个仓库具体哪些目录/代码值得迁移，直接列成开发任务清单。