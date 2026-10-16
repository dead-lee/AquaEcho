# AquaEcho

测试 Apple Watch 扬声器到 iPhone 麦克风的单向声波信道。场景是潜水时的短距离传信：寻找人耳几乎听不到、但在空气、水或塑料壳里仍然比较稳的频率组合。

## 两端

- **AquaEchoWatch**：发送端。按最大可用音量播放测试信号，并记下每次发送的本地时间。
- **AquaEcho**：接收端。用 48 kHz、`playAndRecord` + `measurement`（关闭自动增益）打开麦克风。音频回调里只留一个滑动窗口，按脉宽实时收 bit，攒满 64 bit 后做扩展汉明校验，并和已经收到的发送包比对。处理过的采样随即丢掉，不保存整段会话录音。收到结束消息后，用这些已经算出的结果写评分和 CSV，不再做事后分析。
- 配置通过 Watch Connectivity 从 iPhone 同步到 Watch。下次打开手表会沿用上次配置。

## 信号

每个 bit 是一段单音再加一段静音。0 用低频，1 用高频。单音没有淡入淡出，从第一个样本起就是满幅度。没有前导同步字。一包按 64 bit 从高位到低位依次发送，bit 之间只有这段静音：bit 63–54 低频（Hz / 50，四舍五入），bit 53–44 高频（同样换算），bit 43–41 序号（0–4，即该频率对里的重复序号），bit 40–8 随机内容 33 bit，bit 7–0 校验。默认扫描 15.0–20.0 kHz，步进 500 Hz，两个音至少相隔 1 kHz。单音时长和 bit 间静音读取配置页的「单音时长 (ms)」「静音时长 (ms)」，默认 30 和 15。前导静音和结尾静音读取「前导静音 (ms)」「结尾静音 (ms)」，默认都是 20。64 bit 加上这两段静音不到 3 秒。符号时长仍保留原默认值，不参与发送。

校验是覆盖全部 64 bit 的扩展汉明码，仍然最多纠正 1 bit。编码时算出 8 bit 校验写入 bit 7–0。解调后先用它纠正 1 bit，再按同一位序读出低频、高频和序号。纠错后仍与手表发送的 8 字节不一致，该包记为未通过。没有前导同步字。

配置页在 `onAppear` 和 `onChange(of: mode)` 里整理频率。当前是 CPFSK 时，`freqMinHz` 固定为 15000，`freqMaxHz` 固定为 20000。因此一打开配置页，上下限就和当前模式一致。上下限输入框不限制范围。步进、频率间隔、符号时长、单音时长、静音时长、重复次数、前导静音和结尾静音保持当前值，不因打开页面或切换模式而重置。前导静音和结尾静音仍然可以修改。

每个数值输入前面都有说明，后面都有单位。固定标签是：下限 Hz、上限 Hz、步进 Hz、频率间隔 Hz、符号时长 ms、单音时长 (ms)、静音时长 (ms)、重复次数、前导静音 (ms)、结尾静音 (ms)。单音时长默认 30，静音时长默认 15，前导静音默认 20，结尾静音默认 20。符号时长等其余已有项的默认值不变。

## 为什么放弃 ggwave

本项目最初同时测试了自定义 CPFSK 和开源库 ggwave。实测表明，在 Apple Watch 内置扬声器上，ggwave 无法稳定工作。

ggwave 使用多音调制，能量被分散到多个频率上。Watch 扬声器在近超声频段（15 kHz 以上）频响已经明显下降且不平坦，导致每个子音的有效 SNR 不足，解码成功率极低。相比之下，CPFSK 只发两个纯音，能量集中，同一硬件上可以通过 Goertzel 可靠检出并解调。

因此本项目移除了全部 ggwave 相关代码。除非未来 Apple Watch 配备专门的超声波换能器，否则 ggwave 在当前硬件上不具备实用价值。

## 通过

通过是指 iPhone 解出的 8 字节必须与手表发送的完全一致。只检出能量，或者信噪比够高但比特有错，都不算通过。

解调在音频流上做脉宽检测。不再按 `burstStart` 固定切片，也不做 `bestFrame` 大范围搜索。分析窗 `analysisSamples` 固定 8 ms，步进 `hopSamples` 固定 3 ms。`measureWindow` 只用这一个 8 ms 窗。`absEnd` 固定为 `absStart + analysisSamples`。`absorbTone` 和新开的段都把 `toneEnd` 设成这个 `absEnd`。一个窗是否算有效音调，不用绝对能量门限，必须同时满足：两个目标频率中较大者的 SNR ≥ 6 dB，且两个目标频率的能量比 ≥ 8 dB。已经有一段音调时，必须连续 3 个窗都判成另一频率，而且这三窗都达到上述门限，才按频率结束当前段并开始新段。没满 3 个的反向窗忽略，当前段的 `toneEnd` 用最新的 `absEnd` 更新。当前段还在时，本窗信号功率低于这段 `referencePower` 的 0.1，或者高于它的 10 倍，立刻结束当前段。低于 0.1 是音调已经落到拖尾里；高于 10 倍是这段还没进入稳定单音，后面的真音调要另起一段。没有当前段时，功率低于上一段音调 0.1 的窗也不能新开一段，避免静音里连续几个超门限窗攒成一条假 bit。上一段的功率会跟着新音调往下降，后面的频率对声音变轻时仍然开得了段。处理顺序固定为先合并缺口，再判断时长。两段同频率有效音调之间的缺口小于 6 ms 时，先合并成一段。合并后持续时间不少于 16 ms 才记 1 个 bit：低频是 0，高频是 1。合并后仍短于 16 ms 的丢掉。缺口大于或等于 6 ms 时不合并，两段分别做这个时长判断。攒满 64 bit 后做扩展汉明校验。校验通过（0 错或已纠正 1 bit）且解出的低频、高频与当前频率对一致，才算解调成功。校验不通过也保留这 64 bit 的解调结果并写日志，不丢弃。先纠错再解析，并与对应 `SentPacket` 的 8 字节比较。每处理完一个包，立刻更新已收到计数和当前状态。

Hit 和 SentPacket 按解出的频率对和序号配对。不再按 `pendingHits` / `pendingPackets` 的到达先后配对。收到发送包时，若已有相同序号和频率的 Hit，立刻比对。检出 Hit 时，若已有相同序号和频率的发送包，立刻比对。校验失败时仍按解出的频率对和序号尝试匹配，匹配状态写「校验失败」。`phoneReceiveDate` 固定为这 64 bit 中第 1 个有效 bit 开始时所在音频回调的绝对时间，不用样本偏移再推。这一包解调结束时再记一次当前绝对时间，作为 `demodEndDate`。

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
4. 把手表扬声器靠近 iPhone 底部麦克风。波形峰值归一化到 0.98。程序不修改系统音量。`AVAudioSession` 类别是 `.playback`。`WatchRootView` 用 `.digitalCrownRotation` 调节播放音量，绑定值范围 `0.0...1.0`，步进 `0.05`。初始值是当前 `AVAudioSession.sharedInstance().outputVolume`。旋转表冠时把该值写入 `player.volume` 和 `engine.mainMixerNode.outputVolume`。界面显示这个音量的百分比。低于 0.95 时文字固定为「音量不足，请旋转数码表冠调到最大」，发送仍然继续。开始发送前读取 `AVAudioSession.sharedInstance().outputVolume`，并写入日志「音量 outputVolume=0.xx」。

模拟器没有这条真实声路，评分要在真机上做。模拟器可以确认界面、延长运行是否申请成功，以及日志有没有写进 Documents。

## 手表保持前台

使用 `WKExtendedRuntimeSession(.selfCare)` 保活，确保熄屏不中断发送。熄屏不结束会话，也不中断正在进行的发送。

本机 watchOS SDK 的构造方法是 `WKExtendedRuntimeSession()`，没有 `sessionType` 参数。sessionType 固定为 self-care：`AquaEchoWatch/Info.plist` 的 `WKBackgroundModes` 只有 `self-care`。不在 `applicationWillResignActive` 或启动过早时创建会话，只在 `applicationDidBecomeActive` 之后创建并 `start()`。日志记录「延长运行已在 applicationDidBecomeActive 后启动」。

启动成功后，熄屏、屏幕变暗、返回菜单都不调用 `invalidate()`，发送继续。只有用户点击停止按钮，或按数码表冠离开应用（系统原因 `resignedFrontmost`）时，才调用 `invalidate()` 结束会话并停止发声。`resignedFrontmost` 不重建会话。停止原因写「resignedFrontmost rawValue=X」。

`startIfNeeded` 发现当前会话的状态是 `.running`、`.scheduled` 或 `.notStarted` 时直接返回，不再创建新的 `WKExtendedRuntimeSession`。只有会话为 nil，或状态为 `.invalid` 时才新建。新建之前如果旧会话还在，先 `invalidate()` 并置为 nil。系统以 `.error`、`.expired` 或 `.suppressedBySystem` 收回会话，且不是用户主动结束时，只在 0.5 秒后调用 `startIfNeeded` 重建，不调用 `onStopSound`，也不停止发声。这三种失效的日志是「延长运行失效 reason=原始枚举名 rawValue=X detail=错误描述」。失效回调只处理当前这一次会话，避免清掉刚建好的新会话。

手表界面的根布局是普通 `VStack`，不用 `ScrollView`，也不使用 `.scrollDisabled`。内容超出屏幕时，用 `.contentShape(Rectangle())` 和 `DragGesture` 做只响应手指的滚动。数码表冠只通过 `.digitalCrownRotation` 调节上面的播放音量，不改系统音量。

## CSV

每次测试结束会写入：

`Documents/AquaEcho_Results_yyyyMMdd_HHmmss.csv`

用数据线把 iPhone 连到 Mac，在访达侧边栏打开这台 iPhone 里的 AquaEcho，把 CSV 拖到桌面。也可以在 iPhone 的「文件」App 里，于「我的 iPhone」→ AquaEcho 中看到它。`Info.plist` 打开了 `UIFileSharingEnabled` 和 `LSSupportsOpeningDocumentsInPlace`，所以访达和「文件」都能直接打开 Documents 里的文件。

## 日志

开发阶段的关键事件写入：

`Documents/AquaEcho_Log_yyyyMMdd_HHmmss.txt`

与 CSV 使用同一个 Documents 目录。iPhone 的 `Info.plist` 已设置 `UIFileSharingEnabled = YES` 和 `LSSupportsOpeningDocumentsInPlace = YES`。

关键事件都写入该文件：开始发送、停止发送、当前频率对、发送时间戳、播放结束时间、音量 `outputVolume=0.xx`、错误信息。`WatchModel.stop()` 写「停止发送 原因=原始信息」。用户按停止按钮时原因是「用户按停止按钮」；收到手机 `.stop` 时原因是「收到手机停止指令」；`resignedFrontmost` 时原因是「resignedFrontmost rawValue=X」。其他调用写函数名和关键参数原值，不用归类后的中文代替原始值。手表上每个包的 `play` 返回后额外记一条「播放结束 序号 X 时间 ...」。这条和发送时间一样，先留在发送循环的内存里，循环结束后再一次性同步。日志只写在 Documents 里。发送循环里的日志先写入手表本地文件和内存数组 `pendingLogs`，不在循环内通过 Watch Connectivity 发送，避免打断播放节奏。状态变为「发送完成」或「已停止」之后，再一次性把这批日志发给 iPhone。手表端不提供日志查看界面。iPhone 上可在「日志」页、访达或「文件」App 里看。日志页列出 Documents 里的文件，并在这一栏放「一键清理」。它删除所有 `AquaEcho_Results_` 开头的 `.csv` 和所有 `AquaEcho_Log_` 开头的 `.txt`，完成后界面显示「已清理 CSV 和日志」。

iPhone 每处理完一个包写一条「包 X 前导对齐=是/否 解出=hex或空 通过=是/否 解调耗时=XXXms 解出序号=N或空 是否纠错=是/否 纠错后是否通过=是/否」。没有解出载荷时，解出和解出序号都写「空」。每攒满 64 bit 再写一条「解调=成功/失败 解出低频=X或空 解出高频=X或空 解出序号=X或空 纠错=是/否 校验=通过/失败 解出hex=XXXXXXXXXXXXXXXX或空 耗时=XXXms 匹配=已匹配/无对应包/校验失败」，校验失败也写。未能攒满 64 bit 的不写这条。每个被丢弃的脉冲写一条「丢弃脉冲 频率=低/高 持续=XXms 原因=短于16ms」。每秒写一条「检测峰值 SNR=X.X 能量比=X.X」。每个包结束时再写一条「包 X 结束后窗口剩余 XXXXX 样本」，剩余为 0 也写。

全部包发送完成，或用户在手表上停止之后，手表立刻发送 `kind` 为 `.finished` 的消息，不等日志同步。iPhone 一收到就停止录音，用已经实时算出的各包结果立刻写评分和 CSV，并把界面状态设为「测试完成」。这个状态只由结束消息驱动，不依赖日志是否已经到达，也不再等待事后分析。

每一行是一次发送，包含频率对、随机包的十六进制、序号、Watch 发送时间、iPhone 接收时间、解调结束时间、平均信噪比、双频能量比、通过率、三项得分和总分，以及「本包是否通过」（1 或 0）。另外有「解出低频」「解出高频」「解出序号」「是否纠错」。时间是各自设备的本地时间，并带时区偏移；发送和接收旁边还有 Unix 毫秒，方便事后对位。解调结束时间是攒满 64 bit 并完成校验时的绝对时间。

## 自检

不连真机也可以核对相位连续性、Goertzel、评分边界和 CSV：

```bash
swiftc -O -o /tmp/aquaecho-selfcheck \
  Shared/PacketLayout.swift Shared/ExtendedHamming.swift Shared/TestConfig.swift \
  Shared/Models.swift Shared/Goertzel.swift Shared/CPFSKSynth.swift \
  Shared/Scoring.swift Shared/SignalAnalyzer.swift Shared/CSVExporter.swift \
  SelfCheck/main.swift
/tmp/aquaecho-selfcheck
```

通过时打印 `SELF_CHECK_OK`。
