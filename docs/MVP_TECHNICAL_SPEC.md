# GalaxyCompanion：MVP 技术规格

> 文档状态：开发基线（v0.1）  
> 语言：中文  
> 依据：[`doc.md`](doc.md) 与 [`doc2.md`](doc2.md) 的产品与技术调研结论。
> 重要说明：本文件收敛产品决策，不重新验证外部 SDK、系统权限或第三方 App 行为。凡依赖具体机型、系统版本、地区、审核或真机行为的能力，均以 **PoC / 受限** 标记，不得作为上线承诺。

## 1. 产品定义

**GalaxyCompanion** 是一个面向 iPhone 用户的第三方 Galaxy Watch 配套应用。它由 iPhone App 与安装在 Galaxy Watch 上的自研 Wear OS App 组成，以自有的 BLE/GATT 通道传输数据。

产品的核心价值是：在**不依赖 Android 手机、Samsung Health 云历史或官方 Galaxy Wearable 配套体验**的前提下，让用户在需要时手动将 Galaxy Watch 的基础健康数据同步至 iPhone / Apple Health，并在手机端查看睡眠分析和设备状态。

### 目标用户

- 已拥有兼容 Galaxy Watch、希望在 iPhone 上使用基础健康能力的个人用户。
- 愿意安装自研 Watch App，并接受部分高级能力因型号或权限而不可用的早期采用者。

### 非目标

本产品不是 Galaxy Wearable 或 Samsung Health 的完整替代品，不提供：

- Samsung Account、Samsung Health 云端历史、三星云备份或 Galaxy Store。
- eSIM、支付、固件 OTA、查找手表、完整系统设置管理。
- 电话、接听、拨号、短信发送、通知操作回复或 iMessage 回复。
- 银行卡、交通卡、加密门禁卡的读取、复制或模拟承诺。
- 三星 Sleep Score、Sleep Coaching 或其他三星私有算法的复刻。
- 即时心率面板、自动实时同步、iPhone 通知转发或消息展示。本阶段只保留 Watch 本地缓存与用户主动的健康同步。

## 2. MVP 范围与可行性分级

### 分级定义

| 标记 | 含义 | 发布规则 |
| --- | --- | --- |
| **基础可实施** | 使用公开平台能力且不依赖 Samsung 高级传感器审核的功能。 | 在完成自动化测试与真机验收后可进入 MVP。 |
| **需真机 PoC** | 设计方向成立，但 BLE 角色、手表型号、后台行为或系统权限仍须物理设备验证。 | PoC 未通过前不进入对外承诺。 |
| **受限** | 依赖 Samsung Partner 审核、地区 / Apple Account 条件或特定机型支持。 | 设计为可选能力，不能阻断基础流程。 |
| **不承诺** | 技术、合规或产品边界不允许作为功能目标。 | 不实现，不列入路线图验收。 |

### MVP 功能矩阵

| 模块 | 用户结果 | 技术边界 | 分级 | MVP 验收 |
| --- | --- | --- | --- | --- |
| 连接与重连 | 用户能发现、连接并再次连接已安装自研 App 的手表。 | 仅连接自有 GATT 服务；不接入 Galaxy Wearable 私有协议。 | **需真机 PoC** | 手动断连、App 重启、手机重启后的连接状态可解释且可恢复。 |
| 基础健康同步 | 手机上可查看并保存步数、心率、日总能量与距离数据。 | Watch 端本地缓存，iPhone 仅增量拉取；数据带时间、来源和质量。 | **基础可实施**，连接链路需 PoC | 离线采集后重连不丢失；重复同步不产生重复记录。 |
| HealthKit | 成功手动同步后，已授权的心率、步数与距离自动进入 Apple Health。 | 仅写入获得用户授权的标准类型；日总能量可能包含基础代谢，只在本应用展示，不能伪装为活动能量；所有未写入项必须可见。 | **基础可实施** | 授权、拒绝授权、重复写入和部分写入失败均有可见结果。 |
| 高级健康 | 支持可用的 IBI/HRV、血氧、皮温、运动与呼吸相关指标。 | 由能力矩阵启用；Samsung Sensor SDK 不得成为基础能力的硬依赖。 | **受限** | 在获支持和获批准的真机上采集、同步并正确隐藏不支持项。 |
| 睡眠 | 手机上显示本地估算的休息时段、预计睡眠时长与效率。 | 使用自有规则 / 时间序列引擎；不读取三星云端睡眠历史，不声称三星评分；首版不输出睡眠阶段。 | **需真机 PoC** | 生成带算法版本的睡眠会话；原始数据不足时明确不给出结果。 |
| 诊断 | 用户和开发者能看到型号、系统、连接、MTU、能力、SDK 与错误信息。 | 只诊断自研 App 与公开能力，不探测或调用私有三星协议。 | **基础可实施** | 可导出或展示足以复现连接与同步问题的脱敏状态。 |
| NFC Lab | 用户可用 iPhone 扫描受 Core NFC 支持的标签并保存允许读取的资料。 | Watch Reader 与 Watch HCE 分别检测；不复制受保护卡片。 | **需真机 PoC** | 标签类型 / NDEF 解析、保存、失败说明及能力检测可用。 |

### HealthKit 首批指标

当前首批只写入可安全映射的步数、心率和距离。每条写入样本保留来源元数据，例如 `GWCSource = GalaxyWatch`，以支持去重与来源识别。`CALORIES_DAILY` 是日总能量，可能包含基础代谢，仅在本应用展示；活动能量、楼层、血氧、体温与 Workout 属于后续能力矩阵项，不得预先写入或伪造。

微信不是直接集成目标。若用户所在地的微信版本支持从 Apple Health 读取相关数据，用户可自行授权使用；该下游行为不构成 MVP 验收或兼容性承诺。

## 3. 系统架构与运行约束

### 核心数据流

```text
Galaxy Watch（自研 Wear OS App）
  传感器 / Health Services / 可选 Samsung Sensor Provider
      → 本地样本库
      → 自有 BLE GATT 服务
      ↔ iPhone CoreBluetooth 传输层
      → iPhone 本地持久化
      → HealthKit（经用户授权）
      → Dashboard / Health / Sleep / Diagnostics
```

Watch 端是数据权威缓存：手机离线、蓝牙断连或 iPhone App 被系统终止时，健康样本必须先安全保存到 Watch 本地。iPhone 恢复连接后，以 cursor 为边界进行增量同步，并通过确认、去重、重试与恢复机制保证可重复执行。

### 逻辑分层

```text
UI
  → Feature / ViewModel
  → Use Case
  → Repository
  → Transport / Local Storage / HealthKit / Sensor Provider
```

- UI 不直接访问 CoreBluetooth、HealthKit、SwiftData、Room 或 SDK 回调。
- BLE 层不向业务层泄漏 `CBPeripheral` 等框架对象；跨层只传递值类型业务模型和显式错误。
- 全部功能由 `WatchCapabilities` 驱动。至少覆盖心率、IBI、步数、卡路里、距离、楼层、血氧、皮温、呼吸率、PPG、加速度、EDA、BIA、MF-BIA、ECG、NFC Reader 与 NFC HCE。
- 业务协议须支持版本协商、能力协商、序列号、cursor、确认、重试、分片与续传；具体帧字段留给协议设计阶段确定。
- 原始 PPG 和加速度仅用于短期处理或受控保留，不能无限制写入 iPhone 长期数据库。

### 可选传感器策略

基础实现优先使用 Wear OS Health Services。Samsung Health Sensor SDK 通过独立 provider 接入，必须可在缺少 SDK、未获 Partner 批准或设备不支持时被关闭，而不影响连接、基础健康同步与 HealthKit。

Samsung Sensor SDK 的正式分发批准、包名 / 签名登记、具体 tracker 可用性均属于 **受限** 条件；上线前须单独确认。

> 实施记录（2026-10-08）：原始调研中列出的 Wear Compose 1.7.1 已要求 `compileSdk 37` 与 Android Gradle Plugin 9.1+，不兼容本项目已安装并验证的 API 36 工具链。Watch 工程暂使用 Wear Compose 1.6.2、`compileSdk 36`、AGP 8.10.1 和 Gradle 9.2.1；后续升级 API / AGP 前必须重新完成真机构建验证。

## 4. 睡眠与 NFC 的边界

### 睡眠

睡眠引擎的输入可以包括活动、心率、IBI/HRV、血氧、皮温和可用的 PPG。首版输出仅为带算法版本的本地休息时段、卧床时长、预计睡眠时长和效率；不展示 Light、Deep、REM、觉醒次数或应用睡眠分数。

- 每份结果必须标记 `algorithmVersion` 和置信度 / 数据完整性状态。
- 首版可采用规则与时间序列平滑；不以机器学习为前置条件。
- 当传感器覆盖不足、连续采集不稳定或活动只有日累计语义时，不生成会话，不展示伪精确的睡眠阶段或评分。

### NFC Lab

NFC 独立于健康同步主链路：

```text
iPhone Core NFC → 标签类型 / NDEF / 允许读取的信息 → 本地保存
iPhone → BLE → Watch HCE Profile（仅未来实验路径）
```

- 优先实现 iPhone 标签扫描、NDEF 解析、支持类型识别与本地保存。
- Watch NFC Reader 与 Watch HCE 必须分别检测、分别显示能力，不能互相推断。
- 不读取安全区、不承诺固定 UID，不模拟或复制银行卡、交通卡、MIFARE Classic、DESFire 或加密门禁卡。

## 5. 交付阶段与验收门槛

| 阶段 | 交付目标 | 进入下一阶段的门槛 |
| --- | --- | --- |
| 0. 工程基础 | iOS / Wear OS 工程骨架、共享模型、CI 与基础测试。 | 两端可构建；协议编解码测试通过。 |
| 1. BLE 地基 | 广播、扫描、服务发现、连接状态机、重连、能力交换、系统加密配对门与诊断。 | 至少一台目标 Watch 与一台 iPhone 完成稳定连接和 MITM 加密 Bond PoC；否则不开放健康数据。 |
| 2. 基础健康 | Watch 本地存储、cursor 同步、确认与去重；步数、心率、日总能量与距离。 | 离线采集、断连恢复、重复同步、部分包失败均通过真机测试。 |
| 3. HealthKit | 授权、映射、来源元数据与失败恢复。 | Apple Health 中可验证样本，无重复或错误单位。 |
| 4. 高级健康 | 通过能力矩阵接入已批准 / 支持的高级传感器与 Workout。 | 每一指标在对应机型独立验收；不支持项正确降级。 |
| 5. 睡眠 | 基础会话、关联指标、版本化规则引擎与睡眠报告。 | 至少覆盖正常夜间、数据缺口、跨日与多次同步。 |
| 6. NFC Lab | iPhone Reader、NDEF、保存与 Watch NFC 能力探测。 | 受支持标签与不支持标签均有明确结果；健康主链路不受影响。 |

## 6. 质量、安全与隐私要求

- 健康数据均含时间、单位、来源与质量信息；单位转换和时间边界必须可测试。
- 协议测试至少覆盖正常包、分片、畸形包、重复包、遗漏确认、重试、断连续传与版本不兼容。
- 同步测试至少覆盖 cursor 边界、重复处理、离线积压与部分 HealthKit 写入失败。
- 睡眠测试使用固定 fixture，覆盖活动增量、短暂活动、数据缺失、心率空档、跨日与算法版本变更。
- 诊断与日志必须避免暴露完整健康历史或 NFC 原始敏感信息；导出前进行脱敏。
- 所有系统权限均按最小化原则请求；被拒绝时 App 保持可用并说明缺失能力。
- 仅复用许可证兼容的第三方代码；无明确开源许可的仓库只能参考架构与行为，不复制实现。

## 7. 决策追溯

| 决策 | 收敛结论 | 参考来源 |
| --- | --- | --- |
| 主连接方式 | 使用自有 Watch App 与 BLE/GATT，不采用 Wear OS Data Layer 作为 iPhone 通信方案。 | `doc.md`：架构决定、通信原则；`doc2.md`：连接路线。 |
| 健康数据策略 | Watch 本地缓存、cursor 增量同步、iPhone 写入 HealthKit。 | `doc.md`：健康同步、存储、HealthKit 映射；`doc2.md`：系统结构。 |
| 高级传感器 | Health Services 为基础，Samsung Sensor SDK 可选且受审核 / 机型限制。 | `doc.md`：Samsung SDK 与 Health Provider；`doc2.md`：商业 / 发布问题。 |
| 睡眠策略 | 生成自有本地分析，不宣称读取或复刻三星睡眠结果。 | `doc.md`：睡眠模块与引擎；`doc2.md`：睡眠结论。 |
| 实时与通知策略 | 当前 MVP 不做即时心率、自动同步或通知转发；后续若重新评估，ANCS 等系统路径必须独立 PoC。 | 原始调研中的通知章节仅作为未来参考。 |
| NFC 策略 | 作为独立实验模块，区分 Reader 与 HCE，不提供卡片复制承诺。 | `doc.md`：NFC 模块；`doc2.md`：NFC Reader / Emulator 边界。 |

## 8. 开发启动清单

开始功能开发前，团队必须先完成以下确认：

1. 选定首批用于 PoC 的 iPhone、Galaxy Watch 型号、Wear OS / One UI Watch 版本，并记录到设备兼容矩阵。
2. 在真实设备上验证自有 GATT 服务的发现、连接、MTU、断连及恢复流程。
3. 确认基础 Health Services 指标可用范围，以及 Samsung Sensor SDK 的开发 / 分发授权条件。
4. 单独探测 NFC Reader 与 HCE 能力，未通过则隐藏实验入口或展示不支持原因。

满足以上条件后，先推进“阶段 0–3”的连接、基础健康和 HealthKit 闭环；复杂睡眠可视化和 NFC 模拟均不得抢占 BLE 地基的交付优先级。
