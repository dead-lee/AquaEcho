# AquaEcho 设计基线

最后更新：2026-11-06（去掉信道回看，解调起点就是 seekback）

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
- 手机“日志”页最上面有一键清理；删除所有 `AquaEcho_Scan_*`、`AquaEcho_ScanLog_*`、`AquaEcho_WatchTx_*`、`AquaEcho_Log_*`，清理后直到下一次测试才重新创建日志。
- 手表记录的是播放缓冲区，不是麦克风。扫描时把交给播放器的 Float 样本按发送顺序写入 `AquaEcho_WatchTx_yyyyMMdd_HHmmss.wav`（48 kHz、单声道、32-bit float，与手机录音同一写法）。两包之间按上一包结束到下一包开始的时间补 0，间隔超过 2 秒只补 2 秒。不调用录音、不改成 `playAndRecord`。写完后用 `WCSession.transferFile` 交给手机；手机存进自己的 Documents，结果页可以导出。手表上一次扫描留下的同名文件在下一次扫描开始时删掉，传输副本已经由系统拷走。
- 安装采用覆盖安装，不为了推手表包卸载手机；手表直装反复失败时才允许全量重装（会重新申请权限）。

## 3. 调制解调

实时收发只走 watercomms 对齐版，不再使用 400 Hz 标记音或 Cp=240。

- 帧：前导 9360 样本 + ChirpGap 960 + 训练符号 + 数据符号。Ns=960，Cp=67，无额外尾静音。前导和数据用同一频段。时间结构仍是 Naiser：8 段 960 点下扫，段间 240 点空白，符号为 + − − − − − + −。实时集合都从该集合的高频扫到低频。原版 naiser3 样本只留给 1–4 kHz 的对照测试，不进入实时目录。
- 每个符号的循环前缀与 Java 一致：取 `symbol[Ns-Cp-1 ..< Ns-1]` 共 67 点，再拼上 960 点符号体。接收端跳过这 67 点后做 FFT。
- 训练比特：`pn60` 的前 K 位。K>60 时循环 pn60（watercomms 原版只有 60 个子载波）。
- 数据比特按 watercomms 在各符号间均分，不足一个符号的位置用 `java.util.Random(1)` 填充，再按符号序号交织，再相对上一符号做差分 BPSK。
- 均衡：训练符号频域单抽头 `G = X/Y`，数据符号乘 G 后做差分解调。
- 播放幅度按峰值归一化到 0.98。watercomms 的 int16 缩放是 `32767/N/子载波数`，波形形状相同，电平不同。
- 手机和手表用同一次扫描配置约定顺序。手表按集合依次发送。手机在每个时刻只听当前这一包约定的那一条前导，只用这一包约定的载波解调。相关不过门限、或对齐后 64 bit 不对，都记为这一包失败，不改用别的集合再试。
- 同步仍按 watercomms 的顺序，频段就是这一包的数据频段。96 阶 FIR 的通带是该集合下沿减 200 Hz 到上沿。卷积把峰提前 48 点，峰下标加回。再与这一条前导做 FFT 归一化互相关，阈值 0.20。同一条前导在 8000 样本内只留相关最高的峰，用来躲开重复下扫的旁瓣。这一帧结束前的峰不当成下一包，帧长用刚收下的那一包自己的长度。然后只做一次 `seekback(960, 0.4×峰)`，在这个唯一起点解调。解调用没过滤的原始样本。从该起点跳过 gap 和 Cp，每个符号取频谱。
- 不做 watercomms 的 `channe_look_back`。它在 1–4 kHz 前导上估 `H = Y/X`，取噪声门限（尾部均值×1.5+0.15）以上的最早峰。我们的频段只有 400–2000 Hz 宽，冲激主瓣有一百多点，−13 dB 的旁瓣高过 0.15 的门限，最早峰常落在主瓣前面。干净帧加微弱噪声时，回看起点比真实起点早：C8 168 点、E16 88 点、D16 84 点、S0 67 点，都出了 67 点的循环前缀。2026-11-06 构建 47 的 4 轮录音（手持、桌上、袋子对左手、袋子对右手，8 组各 20 包）用 `ScanReceiver` 重放：带回看合计 256 包，只用 seekback 288 包。手持一轮 C8 7→20，袋子对右手一轮 C8 12→18，其余没有明显变差。Matlab 的 `fre_offset=20`（解调窗再往循环前缀里退 20 点）同样重放是 243 包，不采用。
- 0.20 仍是归一化波形相关，不是响度。watercomms Matlab 的 `MinPeakHeight 0.5` 用的是 `/30000` 之后的未归一化 `xcorr`，声音大就容易过。seekback 起点偏离符号边界、落在循环前缀外的包记为该频段的失败，用来比较频段，不用第二套定时把它捞回来。
- 弱载波：watercomms 的 `Fre_adaptation` 是发之前用反馈选一段连续高信噪比载波，不是单向解调里的擦除。单向扫描不加入这步。
- 实时扫描只使用 0.5–2.5 kHz 的差分 OFDM。4 kHz 以上和 1–4 kHz 的 W0 不再发送。配置版本 6 的默认扫描是 E16、S1，每组 20 包。其余 OFDM 集合留在目录里，默认关闭。
- OFDM 组合都是连续 50 Hz 载波，符号结构与上面相同：A8/B8/C8 各 8 个载波（0.50–0.90、1.00–1.40、1.60–2.00 kHz），D16/E16 各 16 个（0.50–1.30、1.20–2.00 kHz），S0 为 20 个（0.50–1.50 kHz），S1 为 30 个（1.00–2.50 kHz），A40 为 40 个（0.50–2.50 kHz）。载波越少，峰值归一化后每路分到的幅度越大，包也越长。
- 单音短包已经放弃，代码已删除。2026-11-01 构建 46：空气一轮（日志场景误标成密封袋）F08 2/20、F2 0/20、F16 11/20、F20 2/20、F24 0/20，合计 15/100。密封袋一轮前导相关只有 0.20–0.34，100 包都没对齐。中间一轮手表因 workout 未运行没有播放。同一天的空气 OFDM 是 E16 19/20、S1 18/20、A40 14/20。单音一包 3.1 秒、146 个 20 毫秒纯音共用一个起点，没有循环前缀；间隔 300 Hz 的 F2 和 F24 在前导稳定时仍有约 21/146 个音判错，卷积码纠正不了。watercomms 的单音只验证过求救信标：符号拉到 100–200 毫秒、5–10 bps，不是这种 64 bit 短包。报文继续用他们验证过的差分 OFDM。
- 载荷：8 bit 集合号 + 16 bit 包序号 + 40 bit SplitMix64；手机自校验。
- 手机 `ScanReceiver` 流式处理；结果实时更新。

## 4. 极简控制面（声波测试优先）

测试目标是声波链路和手机接收处理能力，不是手机-手表配对握手。控制面只保留最小 best-effort：

- 手机 App 启动时 best-effort 唤起手表并建立 workout；失败只记录，不阻塞测试。
- 手机点开始：
  1. 立即启动麦克风 capture/监听；
  2. 立即 best-effort 发送一次 `start`；
  3. 不等待 `ready`、`watchActive`、`started`、ack；发送失败只记录。
- 手表收到 `start`：立即启动 workout/音频并发波，不等待 UI active，不回 ack 作为门槛。
- **不得有 3 秒“准备”预滚**；收到 start 后直接进入发波，第一包 airtime 不应额外等待。
- 手机停止：立即停止 capture、cancel 接收、后台完成收尾；best-effort 发送 `stop`，不等确认。
- **控制命令只走一条队列**：
  - start/stop/endWorkout 全部使用 `transferUserInfo`，不检查 reachable；
  - 不混用 sendMessage，保证单一 FIFO 队列；
  - 不引入 ack、不判断 active/ready；
  - 手机按用户操作顺序提交，手表按相同顺序消费。
- **start/stop 不做幂等合并**：
  - 每个 start 都开启新一轮；手表已运行时收到 start，先停当前轮再重启；
  - 每个 stop 都停止当前轮；已停止时也消费命令，仅记录；
  - 不允许“重复 start 忽略”或“重复 stop 幂等”的优化。
- 不再使用 `watchActive / watchInactive / started` 作为发送或判定条件；相关状态和测试已删除。
- 不再使用 `pendingStart`、自动重发、`started` 有效性判定。
- 静音、0/140、包丢失都是有效测试结果；结果只由声波包决定，不由配对状态决定。



## 10. watercomms PHY 对齐

### 10.1 已缓存参考

`Reference/watercomms/`，commit `efa5e21a2406d3c6d6c029f14b27fc201d148bd5`，含：
- `naiser3.txt`：9360 样本 = 195 ms 前导；
- `Matlab_Decoder/`；
- Android Java/C++ 源码。

### 10.2 watercomms 与当前实现的差异

| 项 | watercomms | 当前 |
|---|---|---|
| Ns | 960 | 960 |
| CP | 67，`symbol[Ns-Cp-1 ..< Ns-1]` | 同 |
| 前导 | Naiser3 9360 + ChirpGap 960，频段即数据频段 | 同一时间结构，下扫改到该集合频段 |
| 同步 | 数据频段对应的 FIR 后互相关 + seekback + 信道回看最早径 | FIR 后互相关 + seekback，FIR 频段跟着该集合。不做信道回看，窄带里它的最早峰落在旁瓣上。解调仍用原始样本 |
| 信道估计 | 训练符号频域均衡 | 同，`G = X/Y` |
| 调制 | 差分 BPSK-OFDM | 相同，峰值归一化到 0.98。20 毫秒单音短包已放弃 |
| 比特装载 | 符号间均分 + `Random(1)` 填充 | 同 |
| 卷积码/交织 | `{7,5,10}` / JavaRandom(符号序号) | 同 |
| 帧尾 | 无额外 tail | 无 |
| 频率 | 1000–4000 Hz，距离远时收窄 | 实时扫描只在 0.5–2.5 kHz，默认 E16 与 S1 |

### 10.3 对齐原则

- OFDM 行仍用 watercomms 的 Ns、CP、前导时间结构、同步、均衡、差分 BPSK、编码和交织。前导频段等于该集合的数据频段。
- 实时对比限制在 0.5–2.5 kHz 的差分 OFDM。单音短包不再进入扫描。
- 1–4 kHz 的 W0 和 4 kHz 以上的集合退出实时目录。

### 10.4 实施步骤

1. `WatercommsPhy`：实时集合用同一 Naiser 时间结构，下扫落在该集合频段。帧 = preamble + 960 gap + (training + data)*(960+67)。已接入 `ScanProtocol.makeFrame`。
2. TX：训练符号 + 差分 BPSK + 卷积码/交织，不用 400 marker。
3. RX：按扫描配置的顺序，当前包只相关自己的前导，只在 seekback 起点解调一次。载波用这一包约定的集合。失败不改频段重试。
4. 配置版本 6 把已保存的集合选择重置为 E16、S1。手机开始时把这份配置发给手表。
5. 日志记录前导相关峰和每集合成功率。频偏、均衡系数留到下一轮诊断。

### 10.5 测试矩阵

- 方法：每个包只按约定的 OFDM 载波解调一次；
- 本轮频段：E16、S1，每组 20 包；
- 指标：每组通过率、前导相关、数据 SNR。

### 10.6 验收

- 本轮只比较 E16 和 S1 在真机上的通过率；
- 不再把 1–4 kHz 或 4 kHz 以上当作实时对照；
- 不能再用 400 marker/Cp=240 版本冒充 watercomms 结果。


## 10. watercomms 参考

- 代码/文档快照：`Reference/watercomms/`；
- 来源 commit：`efa5e21a2406d3c6d6c029f14b27fc201d148bd5`；
- 对比点：Ns=960、Cp=67、Naiser preamble、频域/时域均衡、差分 BPSK、卷积码/交织；
- 缓存不参与构建。

## 11. 诊断记录（不改调制解调）

只增加日志，不改变阈值、定时、OFDM、译码或通过判定。

### 手表 TX

每个包记录：

- set ID、packet index、payload hex；
- 帧样本数、airtime、carrier 数、data symbols；
- 前导样本数、Cp、Ns；
- 调度发送时间；
- 音频路由、采样率、系统音量、engine/player 状态。

### 手机 RX

- 录音链路：输入路由、采样率、声道、session category、是否 running；
- 每个前导：样本位置、归一化相关、seekback 后起点、候选集合、数据窗口范围；
- 成功帧：set、packet、data SNR、offset；
- 失败帧：未匹配原因/候选数，不改变原有失败判定。

### 验收

- 不改变任何既有测试结果；
- 新增日志字段可在 `AquaEcho_Log_*.txt` 中直接检索；
- WAV/CSV 逻辑不变。

## 5. 停止与日志

- 停止后 `ScanReceiver.cancel()` 立即丢弃积压 ingest；`finish` 不处理 pending。
- capture.stop 在后台执行；receiver.cancel 使用独立锁；主线程不等待。
- 日志记录发送/接收/停止的阶段，但日志状态不阻塞、不改判结果。
- 主线程 watchdog 保留，用于发现实现层卡死，不参与测试判定。

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

## 7. 失败 case 回归测试

必须在本机运行，不能只靠真机：

1. **start 并发**：`StartAdmission`，第二个 begin 必须失败，结束后才允许下一次。
2. **start 重发状态**：`StartRetryState`，发送失败才 pending；发送成功后即使 `watchReady=false` 也不得 pending。
3. **后台 workout 策略**：`WorkoutStartPolicy`，background 必须拒绝启动。
4. **日志 UI 合流**：`LogUIBatcher`，大量日志只能触发有限次数 UI 更新，且保留尾部内容。
5. **停止异步**：`StopHandoff`，停止调用必须立即返回，慢 finish 不得阻塞调用线程。
6. **窄带起点**：C8 干净帧加微弱噪声经 `ScanReceiver` 收下，整包能解出，记录的帧起点（seekback）离真实起点不超过 100 点。seekback 在 400 Hz 频段上约早 80 点，原来的最早径早 168 点。只喂样本，不提供手表状态。
7. **失焦不等于停止**：`WatchRuntimePolicy` 对 `willResignActive` 保持播放；只有 `didEnterBackground` 才停止并结束 workout。手机 `ScanReceiver` 没有手表状态参数，一段合法录音必须解出。
8. **分频段前导**：每个集合各发一包，前导落在该集合频段，`ScanReceiver` 必须解出。081656 / 081831 是共用 1–4 kHz 前导时的录音，不再作为这条的通过条件。
9. **发送缓冲**：`PlaybackBufferLog` 写入的样本必须与交给播放器的缓冲逐点相同，包间补 0 的个数等于间隔乘以 48000。不打开音频输入。

测试命令：`swift test`。

## 8. 修改与验收流程

1. 改代码前更新本文件的“最后更新”和相关章节。
2. `git diff` 对照本文件逐条 review；不得引入第 3 条之外的新方案。
3. 自测：
   - 模拟器：页面启动、手指滚动、系统 HUD（模拟器音量固定，只能验证布局/控件存在）。
   - 真机：表冠只出现一个系统 HUD；正反向改变系统音量；手指滚动；扫描完成前后台行为。
4. 构建 device 版；手机/手表覆盖安装；只要手表直装反复失败，才全量重装。
5. 每轮更新 README 的对应说明。

## 9. 分阶段实施

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
