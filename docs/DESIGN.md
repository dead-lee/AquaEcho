# AquaEcho 设计基线

最后更新：2026-10-26（31：启动重发/诊断/后台 guard）

本文是代码修改的权威依据。任何代码改动前，必须先更新本文；代码 review、自测、真机安装都以本文为准。

## 1. 产品目标

- 手表扬声器向 iPhone 麦克风单向发送 64 bit 测试包，不依赖蓝牙传输声波数据。
- 测试场景：空气、空气+密封袋、水下+密封袋。
- 目标：整体 80% 的包完全正确；单包偶发丢失可接受。
- 手机实时解码，结果随包更新；停止时只落盘 WAV/CSV，不做整段事后分析。

## 2. 不可砍掉的壳子功能

- 手机四 tab：测试、结果、配置、日志。
- 手机录音、WAV、CSV、分析日志、结果页。
- 手机开始/停止测试；手表不提供开始/停止按钮。
- 手机 App 启动唤起手表并建立 workout 会话。
- 手表前台保活；扫描完成不结束 session；手机/手表 App 被切到后台时结束。
- 手机“日志”页最上面有一键清理；删除所有 `AquaEcho_Scan_*`、`AquaEcho_ScanLog_*`、`AquaEcho_Log_*`，清理后直到下一次测试才重新创建日志。
- 安装采用覆盖安装，不为了推手表包卸载手机；手表直装反复失败时才允许全量重装（会重新申请权限）。

## 3. 调制解调

- 帧：30 ms 公共 400 Hz 标记音 + 10 ms guard + OFDM 训练 + S 个数据符号（20 ms + 5 ms CP）+ 20 ms 尾静音。
- 载荷：8 bit 集合号 + 16 bit 包序号 + 40 bit SplitMix64；手机自校验。
- 标记音在数据频段之外；接收器只扫 400 Hz。
- 手机 `ScanReceiver` 流式处理；结果实时更新。
- 已知弱项：S3（4–8 kHz）在 08:20 实测为 7/20；整体 124/140（88.6%）。S3 单独评估，不作为全局失败。

## 4. 启动、重发与诊断

### 4.1 start 发送

- 手机开始录音时先记录 `watchReady / activated / reachable`；
- `send(.start)` 失败（WCSession 未激活/不可达）时不得再写“请手动点开始”；
- 进入 `pendingStart`，在收到手表 `.ready`、`onActivated(true)` 或 `onReachable(true)` 时自动重发；
- 重发成功后清除 pending；重复 `.start` 由手表 `isRunning` 幂等忽略；
- 日志必须记录每次发送的 `reason / 返回值 / watchReady / activated / reachable`。

### 4.2 workout 启动

- `WorkoutKeeper.startIfNeeded(source:)` 必须记录来源；
- 若 `WKApplication.shared().applicationState == .background`，直接跳过并记录 `source`，不得尝试启动；
- 调用来源包括：`appDidBecomeActive`、`workoutConfiguration`、`phoneStart`、`scenePhaseActive`、`pendingWorkout`、`recover`。

## 5. 音量与前台（A 方案）

### 5.1 必须达到

- 手表 App 内用数码表冠调**系统输出音量**，和 Apple Podcasts/Music 一样。
- 音量反馈只允许**系统原生 HUD**；App 不再自绘音量条。
- 手指上下滑动页面；表冠不被 App 自绘控件抢占。
- 扫描完成后保持 workout；用户切到后台才结束。

### 5.2 实现结构

`WKInterfaceVolumeControl` 只能放在 WatchKit storyboard。当前 single-target SwiftUI watch app 没有该容器，因此目标结构为：

- 采用**单 target WatchKit app**（Stage 0 已验证）：
  - `AquaEchoWatch` 同时包含 storyboard、`WatchInterfaceController`、`WatchModel`、`WorkoutKeeper`、`TonePlayer`；
  - `main.swift` 调用 `WKApplicationMain(..., WatchAppDelegate)` 作为入口；
  - `Info.plist` 设置 `WKApplication=YES`、`WKMainStoryboardName=Interface`；
  - 不需要单独的 WatchKit extension target；`WKApplicationMain` 让 storyboard 在 simulator/真机启动。
- 手机 App 仍嵌入 `AquaEchoWatch`；companion 关系不变。
- HealthKit/workout-processing entitlement 保留在 watch app target。
- `WKInterfaceVolumeControl(origin: .local)` 放在 storyboard；用户聚焦该控件时表冠调系统音量。
- 页面默认允许手指滚动；进入音量控件时 `focus()`，离开时 `resignFocus()`。
- **Stage 3 实测 29：表冠滚页面，说明一次性 `willActivate.focus()` 没有稳定获得焦点。**
- 修正：增加显式“调节音量”按钮；点击后 `focus()`，并在页面激活后 0.5 s/1.5 s 重试；界面明确提示“先点音量，再转表冠”。
- 不得用 `.digitalCrownRotation` 抢回表冠；焦点失败只能继续修 WatchKit 控件。
- 不再存在 `.digitalCrownRotation`、`playbackVolume`、自定义 `VolumeBar`。

### 5.3 前台/会话

- 手表 `WorkoutKeeper` 启动 workout；扫描完成不结束。
- `applicationDidEnterBackground` 结束 workout；`applicationWillResignActive` 不结束。
- 手机切后台发 `.endWorkout`；手表直接结束。
- 不使用 Control Center 作为音量路径；不使用 5 秒延时猜测。

## 6. 当前代码与设计差距（2026-10-26 review）

- 28 删除了自定义 `VolumeBar`，但同时删除了表冠控制，未实现 `WKInterfaceVolumeControl`；表冠没有任何接收者。**不符合 4.1/4.2。**
- 28 的 `WatchRootView` 是 SwiftUI single-target；没有 WatchKit storyboard/extension。**不符合 4.2。**
- 28 仍显示系统音量文字，但系统 HUD 在空闲状态不接管表冠。**不符合 4.1。**
- 27 的绿色系统 HUD + 橙色自定义条是两个来源叠加；已删除自定义条，但系统 HUD 的控制层没有补上。**符合“只留一条”的目标，但控制层缺失。**
- 其余壳子/实时接收器/清理逻辑与本设计一致，待 A 完成后再做一次全量回归。

## 7. 修改与验收流程

1. 改代码前更新本文件的“最后更新”和相关章节。
2. `git diff` 对照本文件逐条 review；不得引入第 3 条之外的新方案。
3. 自测：
   - 模拟器：页面启动、手指滚动、系统 HUD（模拟器音量固定，只能验证布局/控件存在）。
   - 真机：表冠只出现一个系统 HUD；正反向改变系统音量；手指滚动；扫描完成前后台行为。
4. 构建 device 版；手机/手表覆盖安装；只要手表直装反复失败，才全量重装。
5. 每轮更新 README 的对应说明。

## 8. 分阶段实施

### Stage 0：WatchKit 容器可行性（已完成 2026-10-26）

- 建立最小 `Interface.storyboard` + `WatchInterfaceController`；
- `main.swift` 使用 `WKApplicationMain`；
- 模拟器已启动并显示 `Stage 0 WatchKit`；
- 结论：单 target WatchKit app 可行，不需要 extension；下一步 Stage 1 放 `WKInterfaceVolumeControl`。

### Stage 1：音量控件（模拟器通过）

- storyboard 使用 `<volumeControlView>`，outlet 已连接；
- 模拟器显示原生扬声器控件，`willActivate` 的 `focus()` 日志正常；
- 真机系统音量验证放到 Stage 3。

### Stage 2：迁 UI/后端（模拟器通过）

- `WatchInterfaceController` 接 `WatchModel`；
- 保留 workout/HealthKit/WatchConnectivity；
- 手机开始/停止、完成消息、后台结束；
- 音量控件移到标题下方，页面可滚动；
- 四 tab/录音/结果/清理不动。

### Stage 3：构建与安装

- build 29 已安装；实测表冠滚页面，音量控件未获得焦点；
- build 30：显式“调节音量”按钮 + 延迟 focus 重试；
- 覆盖安装；手表失败时按用户授权全量重装；
- 完成第 6 节验收并更新 README。
