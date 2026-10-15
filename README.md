# AquaEcho

测试 Apple Watch 扬声器到 iPhone 麦克风的单向声波信道。场景是潜水时的短距离传信：寻找人耳几乎听不到、但在空气、水或塑料壳里仍然比较稳的频率组合。

## 两端

- **AquaEchoWatch**：发送端。按最大可用音量播放测试信号，并记下每次发送的本地时间。
- **AquaEcho**：接收端。用 48 kHz、`playAndRecord` + `measurement`（关闭自动增益）录音，用 Goertzel 测两个目标频率的能量和信噪比，按固定标准打 0–100 分。
- 配置通过 Watch Connectivity 从 iPhone 同步到 Watch。下次打开手表会沿用上次配置。

## 两种信号

1. **自定义 CPFSK**：两个频率分别代表 0 和 1，切换时相位连续。载荷是新生成的随机 8 字节，前面另有 `0xAA 0x55` 同步头。
2. **ggwave**：通过 Swift Package Manager 集成 [ggwave-spm](https://github.com/ggerganov/ggwave-spm)。使用超声协议，并按步进改起始频率。同样发送随机 8 字节，重复多次。ggwave 自带 Reed-Solomon。

CPFSK 默认扫描 15.0–20.0 kHz，步进 500 Hz，两个音至少相隔 1 kHz。ggwave 模式下 `freqMinHz` 默认 15000，`freqMaxHz` 默认 16000；界面上这两个输入限制在 15000–16000。`GGWaveBand.band` 的高频固定为低频加 1000 Hz。

## 评分

总分是四项相加：

| 项目 | 满分 | 规则 |
| --- | --- | --- |
| 信噪比 | 45 | ≥25 dB 45；20–25 35；15–20 25；10–15 15；5–10 5；低于 5 为 0 |
| 稳定性 | 20 | 重复发送的能量变异系数：<10% 20；10–20% 15；20–30% 8；>30% 0 |
| 双频区分度 | 15 | 两个目标频率的能量比：≥6 dB 15；3–6 10；1–3 5；<1 为 0 |
| 可解码性 | 20 | ggwave 按解码成功率：≥95% 20；80–95% 15；60–80% 10；40–60% 5；<40% 0。CPFSK 取信噪比和稳定性两项归一化后的平均值，再缩放到 20 分 |

总分 ≥ 80 的频率对会标成推荐。

## 怎么跑

1. 用 Xcode 打开 `AquaEcho.xcodeproj`，给两个 target 选好你的开发团队。Bundle ID 目前是 `com.deadlee.AquaEcho`。
2. 把 iPhone App 装到手机上，Watch App 会一起装上。打开手表上的 AquaEcho 后让它留在前台；应用自己会申请延长运行，熄屏也不会被系统送回表盘。
3. 在 iPhone 上设好频率、步进、重复次数，点「同步到 Watch」，再点「开始测试」。
4. 把手表扬声器靠近 iPhone 底部麦克风。播放器音量保持 `engine.mainMixerNode.outputVolume = 1`、`player.volume = 1`，波形峰值归一化到 0.98。ggwave 多音如果直接用音量 100 会削波，所以编码幅度上限是 50，播之前再归一化到峰值 0.98。程序不修改系统音量。开始发送前读取 `AVAudioSession.sharedInstance().outputVolume`，并写入日志「音量 outputVolume=0.xx」。低于 0.95 时状态文字固定为「音量不足，请旋转数码表冠调到最大」，发送仍然继续。

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

关键事件都写入该文件：开始发送、停止发送、当前频率对、发送时间戳、音量 `outputVolume=0.xx`、错误信息。日志只写在 Documents 里。手表端不提供日志查看界面。iPhone 上的同一份事件仍经 Watch Connectivity 写入手机 Documents，可在「日志」页、访达或「文件」App 里看。日志页列出 Documents 里的文件，并在这一栏放「一键清理」。它删除所有 `AquaEcho_Results_` 开头的 `.csv` 和所有 `AquaEcho_Log_` 开头的 `.txt`，完成后界面显示「已清理 CSV 和日志」。

每一行是一次发送，包含频率对、随机包的十六进制、序号、Watch 发送时间、iPhone 接收时间、平均信噪比、变异系数、双频能量比、ggwave 解码成功率（CPFSK 留空）、四项得分和总分。时间是各自设备的本地时间，并带时区偏移；旁边还有 Unix 毫秒，方便事后对位。

## 自检

不连真机也可以核对相位连续性、Goertzel、评分边界和 CSV：

```bash
swiftc -O -o /tmp/aquaecho-selfcheck \
  Shared/GGWaveBand.swift Shared/PacketLayout.swift Shared/TestConfig.swift \
  Shared/Models.swift Shared/Goertzel.swift Shared/CPFSKSynth.swift \
  Shared/Scoring.swift Shared/SignalAnalyzer.swift Shared/CSVExporter.swift \
  SelfCheck/main.swift
/tmp/aquaecho-selfcheck
```

通过时打印 `SELF_CHECK_OK`。
