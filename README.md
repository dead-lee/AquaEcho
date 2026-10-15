# AquaEcho

测试 Apple Watch 扬声器到 iPhone 麦克风的单向声波信道。场景是潜水时的短距离传信：寻找人耳几乎听不到、但在空气、水或塑料壳里仍然比较稳的频率组合。

## 两端

- **AquaEchoWatch**：发送端。按最大可用音量播放测试信号，并记下每次发送的本地时间。
- **AquaEcho**：接收端。用 48 kHz、`playAndRecord` + `measurement`（关闭自动增益）打开麦克风。音频回调里只留一个滑动窗口，实时检出能量突发，立刻做 Goertzel 测量和 CPFSK 解调，并和已经收到的发送包比对。处理过的采样随即丢掉，不保存整段会话录音。收到结束消息后，用这些已经算出的结果写评分和 CSV，不再做事后分析。
- 配置通过 Watch Connectivity 从 iPhone 同步到 Watch。下次打开手表会沿用上次配置。

## 信号

自定义 CPFSK：两个频率分别代表 0 和 1，切换时相位连续。载荷是新生成的随机 8 字节，前面另有 `0xAA 0x55` 同步头。默认扫描 15.0–20.0 kHz，步进 500 Hz，两个音至少相隔 1 kHz。

配置页在 `onAppear` 和 `onChange(of: mode)` 里整理频率。当前是 CPFSK 时，`freqMinHz` 固定为 15000，`freqMaxHz` 固定为 20000。因此一打开配置页，上下限就和当前模式一致。上下限输入框不限制范围。步进、频率间隔、符号时长、重复次数、前导静音和结尾静音保持当前值，不因打开页面或切换模式而重置。

## 为什么放弃 ggwave

本项目最初同时测试了自定义 CPFSK 和开源库 ggwave。实测表明，在 Apple Watch 内置扬声器上，ggwave 无法稳定工作。

ggwave 使用多音调制，能量被分散到多个频率上。Watch 扬声器在近超声频段（15 kHz 以上）频响已经明显下降且不平坦，导致每个子音的有效 SNR 不足，解码成功率极低。相比之下，CPFSK 只发两个纯音，能量集中，同一硬件上可以通过 Goertzel 可靠检出并解调。

因此本项目移除了全部 ggwave 相关代码。除非未来 Apple Watch 配备专门的超声波换能器，否则 ggwave 在当前硬件上不具备实用价值。

## 通过

通过是指 iPhone 解出的 8 字节必须与手表发送的完全一致。只检出能量，或者信噪比够高但比特有错，都不算通过。

解调在音频流里完成。按符号时长切分，比较两个目标频率的能量：低频一侧是 0，高频一侧是 1。比特从高位排起，先对齐前面的 `0xAA 0x55`，再取出后面的 8 字节，与已经收到的 `SentPacket` 逐字节比较。每处理完一个包，立刻更新已收到计数和当前状态。

一个频率对的通过率 = 载荷完全一致的包数 / 该频率对的总包数。

## 评分

总分是三项相加，满分 100。正好落在分界上的值记入更高一档：信噪比正好 25 dB 得 40、正好 20 dB 得 32；双频能量比正好 6 dB 得 20；通过率正好 100% 得 40、正好 80% 得 32。

| 项目 | 满分 | 规则 |
| --- | --- | --- |
| 信噪比 | 40 | ≥25 dB 得 40；20–25 得 32；15–20 得 24；10–15 得 16；5–10 得 8；低于 5 得 0 |
| 双频区分度 | 20 | ≥6 dB 得 20；3–6 得 12；1–3 得 6；低于 1 得 0 |
| 通过率 | 40 | 100% 得 40；80–100% 得 32；60–80% 得 24；40–60% 得 16；20–40% 得 8；低于 20% 得 0 |

不再计算稳定性（变异系数），也不再使用原来的可解码性。总分 ≥ 80 的频率对会标成推荐。

## 怎么跑

1. 用 Xcode 打开 `AquaEcho.xcodeproj`，给两个 target 选好你的开发团队。Bundle ID 目前是 `com.deadlee.AquaEcho`。
2. 把 iPhone App 装到手机上，Watch App 会一起装上。打开手表上的 AquaEcho 后让它留在前台；应用自己会申请延长运行，熄屏也不会被系统送回表盘。
3. 在 iPhone 上设好频率、步进、重复次数，点「同步到 Watch」，再点「开始测试」。
4. 把手表扬声器靠近 iPhone 底部麦克风。播放器音量保持 `engine.mainMixerNode.outputVolume = 1`、`player.volume = 1`，波形峰值归一化到 0.98。程序不修改系统音量。开始发送前读取 `AVAudioSession.sharedInstance().outputVolume`，并写入日志「音量 outputVolume=0.xx」。低于 0.95 时状态文字固定为「音量不足，请旋转数码表冠调到最大」，发送仍然继续。

模拟器没有这条真实声路，评分要在真机上做。模拟器可以确认界面、延长运行是否申请成功，以及日志有没有写进 Documents。

## 手表保持前台

使用 `WKExtendedRuntimeSession(.selfCare)` 保活，确保熄屏不中断发送。熄屏不结束会话，也不中断正在进行的发送。

本机 watchOS SDK 的构造方法是 `WKExtendedRuntimeSession()`，没有 `sessionType` 参数。sessionType 固定为 self-care：`AquaEchoWatch/Info.plist` 的 `WKBackgroundModes` 只有 `self-care`。不在 `applicationWillResignActive` 或启动过早时创建会话，只在 `applicationDidBecomeActive` 之后创建并 `start()`。日志记录「延长运行已在 applicationDidBecomeActive 后启动」。

启动成功后，熄屏、屏幕变暗、返回菜单都不调用 `invalidate()`，发送继续。只有用户点击停止按钮，或按数码表冠离开应用（系统原因 `resignedFrontmost`）时，才调用 `invalidate()` 结束会话并停止发声。

手表界面的根布局是普通 `VStack`，不用 `ScrollView`，也不使用 `.scrollDisabled`。内容超出屏幕时，用 `.contentShape(Rectangle())` 和 `DragGesture` 做只响应手指的滚动。不添加 `.digitalCrownRotation`，也不写任何表冠事件。音频播放期间由系统把数码表冠分给音量调节。程序不直接改系统音量。

## CSV

每次测试结束会写入：

`Documents/AquaEcho_Results_yyyyMMdd_HHmmss.csv`

用数据线把 iPhone 连到 Mac，在访达侧边栏打开这台 iPhone 里的 AquaEcho，把 CSV 拖到桌面。也可以在 iPhone 的「文件」App 里，于「我的 iPhone」→ AquaEcho 中看到它。`Info.plist` 打开了 `UIFileSharingEnabled` 和 `LSSupportsOpeningDocumentsInPlace`，所以访达和「文件」都能直接打开 Documents 里的文件。

## 日志

开发阶段的关键事件写入：

`Documents/AquaEcho_Log_yyyyMMdd_HHmmss.txt`

与 CSV 使用同一个 Documents 目录。iPhone 的 `Info.plist` 已设置 `UIFileSharingEnabled = YES` 和 `LSSupportsOpeningDocumentsInPlace = YES`。

关键事件都写入该文件：开始发送、停止发送、当前频率对、发送时间戳、音量 `outputVolume=0.xx`、错误信息。日志只写在 Documents 里。发送循环里的日志先写入手表本地文件和内存数组 `pendingLogs`，不在循环内通过 Watch Connectivity 发送，避免打断播放节奏。状态变为「发送完成」或「已停止」之后，再一次性把这批日志发给 iPhone。手表端不提供日志查看界面。iPhone 上可在「日志」页、访达或「文件」App 里看。日志页列出 Documents 里的文件，并在这一栏放「一键清理」。它删除所有 `AquaEcho_Results_` 开头的 `.csv` 和所有 `AquaEcho_Log_` 开头的 `.txt`，完成后界面显示「已清理 CSV 和日志」。

全部包发送完成，或用户在手表上停止之后，手表立刻发送 `kind` 为 `.finished` 的消息，不等日志同步。iPhone 一收到就停止录音，用已经实时算出的各包结果立刻写评分和 CSV，并把界面状态设为「测试完成」。这个状态只由结束消息驱动，不依赖日志是否已经到达，也不再等待事后分析。

每一行是一次发送，包含频率对、随机包的十六进制、序号、Watch 发送时间、iPhone 接收时间、平均信噪比、双频能量比、通过率、三项得分和总分，以及「本包是否通过」（1 或 0）。时间是各自设备的本地时间，并带时区偏移；旁边还有 Unix 毫秒，方便事后对位。

## 自检

不连真机也可以核对相位连续性、Goertzel、评分边界和 CSV：

```bash
swiftc -O -o /tmp/aquaecho-selfcheck \
  Shared/PacketLayout.swift Shared/TestConfig.swift \
  Shared/Models.swift Shared/Goertzel.swift Shared/CPFSKSynth.swift \
  Shared/Scoring.swift Shared/SignalAnalyzer.swift Shared/CSVExporter.swift \
  SelfCheck/main.swift
/tmp/aquaecho-selfcheck
```

通过时打印 `SELF_CHECK_OK`。
