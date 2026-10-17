# AquaEcho

测试 Apple Watch 扬声器到 iPhone 麦克风的单向声波信道。场景是潜水时的短距离传信：寻找人耳几乎听不到、但在空气、水或塑料壳里仍然比较稳的频率组合。

## 两端

- **AquaEchoWatch**：发送端。按最大可用音量播放测试信号，并记下每次发送的本地时间。
- **AquaEcho**：接收端。用 48 kHz、`playAndRecord` + `measurement`（关闭自动增益）打开麦克风。音频回调只把采样追加进调试录音并立刻返回，解调在旁边的队列里做。结束前先等这个队列把已经收到的采样处理完，再写整段 `AquaEcho_Recording_*.wav` 和评分。解调按当前频段带通，再用 Naiser 前导对齐，按 OFDM 符号解出编码比特，维特比译码还原 64 bit 载荷，并和已经收到的发送包比对。收到结束消息后，用这些已经算出的结果写评分和 CSV，不再做事后分析。
- 配置通过 Watch Connectivity 从 iPhone 同步到 Watch。下次打开手表会沿用上次配置。

## 信号

调制方式按 [watercomms](https://github.com/uw-x/watercomms) 的默认数据通路：频段 1000–4000 Hz，Naiser 前导同步，然后是差分 BPSK 的 OFDM。默认只有这一段，步进和频率间隔都是 3000 Hz。符号由这段里的子载波组成，间距是采样率除以符号长度，0 对应实部 +1，1 对应实部 −1。第一个 OFDM 符号是他们的 `pn60` 训练序列，后面的数据符号相对前一个符号做差分。每个符号前面加循环前缀，没有淡入淡出。载荷本身没有同步字，也没有校验位：64 bit 从高位到低位是 bit 63–54 低频（Hz / 50，四舍五入），bit 53–44 高频，bit 43–41 序号（0–4），bit 40–0 随机内容 41 bit。空中发送前用 watercomms 实时通路的卷积码，生成多项式 7 和 5，约束长度 10，码率 1/2，末尾再刷 9 个 0，得到 146 个编码比特。

前导直接使用 watercomms 的 `naiser3` 波形，9360 点，约 195 ms，峰值归一化到 0.98。它是 8 段带内波形，PN 为 `1, -1, -1, -1, -1, -1, 1, -1`，段间 240 点静音，文件末尾没有再补静音。符号长度读取「符号时长 (ms)」，默认 20，对应 48 kHz 下 960 点。循环前缀读取「循环前缀 (ms)」，默认 1.4，对应他们 Ns=960 时的 67 点。前导和第一个符号之间的间隔读取「静音时长 (ms)」，默认 20，对应 `ChirpGap` 的 960 点；这 960 点里的前 240 点补上前导最后一段的静音。包前后还有「前导静音 (ms)」「结尾静音 (ms)」，默认都是 20。按默认参数，一整包远小于 3 秒。配置里仍保留单音时长和线性调频时长，发送不再读取。

64 bit 全部是载荷。卷积译码把 146 个编码比特还原成这 64 bit。收到的编码比特和译码结果重新编码后不一致时，日志记「纠错=是」。还原后的 8 字节必须和手表发送的完全一致才算通过。解出的低频、高频与当前正在听的频率对一致时，日志记「校验=通过」；对不上则记「校验=失败」。

配置页在 `onAppear` 和 `onChange(of: mode)` 里把频段和符号参数设成 watercomms 的默认值：下限 1000 Hz，上限 4000 Hz，步进 3000 Hz，频率间隔 3000 Hz，符号时长 20 ms，循环前缀 1.4 ms，静音时长 20 ms。手机上如果还存着 10 kHz 以上的旧扫描，启动时也会改成这一组。重复次数、前导静音和结尾静音保持当前值。

每个数值输入前面都有说明，后面都有单位。固定标签是：下限 Hz、上限 Hz、步进 Hz、频率间隔 Hz、符号时长 (ms)、循环前缀 (ms)、静音时长 (ms)、重复次数、前导静音 (ms)、结尾静音 (ms)。符号时长默认 20，循环前缀默认 1.4，静音时长默认 20，前导静音和结尾静音默认 20。

## 为什么放弃 ggwave

本项目最初同时测试了自定义 CPFSK 和开源库 ggwave。实测表明，在 Apple Watch 内置扬声器上，ggwave 无法稳定工作。

ggwave 使用多音调制，能量被分散到多个频率上。Watch 扬声器在近超声频段（15 kHz 以上）频响已经明显下降且不平坦，导致每个子音的有效 SNR 不足，解码成功率极低。

因此本项目移除了全部 ggwave 相关代码。当前调制改成 watercomms 的差分 OFDM：能量只放在这一对频率之间的子载波上，用 Naiser 前导对齐，用训练符号做均衡。除非未来 Apple Watch 配备专门的超声波换能器，否则 ggwave 在当前硬件上不具备实用价值。

## 通过

通过是指 iPhone 解出的 8 字节必须与手表发送的完全一致。只检出能量，或者信噪比够高但比特有错，都不算通过。

解调先对滑动窗口做 96 阶带通，通带是当前频率对再向低侧放宽 200 Hz，高侧停在频率对上沿，并补上滤波器的群延迟。1000–4000 Hz 时这就是 find_symbol 的 800–4000 Hz。然后用 `naiser3` 做线性相关。正峰先按 find_symbol 检查尖度：左右各 1000 点里超过半峰的个数，符号长度 960 点时不能多于 150，更长时不能多于 80。尖峰彼此至少隔开 2400 点，最多留三个。每个尖峰再做 Naiser 差分相关，得分达到 0.6 才收下。起点用这个相关峰，和 evalSegv2 一样，不用 Naiser 分数平台的后沿。不用绝对能量门限，也不做整段录音上的大范围搜帧。解出的频率对不上当前正在听的这一对时，不把听音位置推到下一对。对齐后按「前导 9360 点 + 静音间隔」切出第一个 OFDM 符号。训练符号只估计频域均衡系数。数据符号先均衡，再和前一个符号比相位：相位落在 ±90° 以外记 1，否则记 0。编码比特的顺序和发送时从低子载波到高子载波的顺序一致。攒满 146 个编码比特后做维特比译码，得到 64 bit 载荷。解出的低频、高频与当前频率对一致，才算解调成功，日志写「校验=通过」。对不上则写「校验=失败」，也保留译码结果，不丢弃。译码时如果改过编码比特，日志写「纠错=是」。先译码再解析，并与对应 `SentPacket` 的 8 字节比较。每处理完一个包，立刻更新已收到计数和当前状态。信噪比是子载波功率相对带外噪声的比，能量比是最弱子载波相对同一噪声的比。

Hit 和 SentPacket 按解出的频率对和序号配对。不再按 `pendingHits` / `pendingPackets` 的到达先后配对。收到发送包时，若已有相同序号和频率的 Hit，立刻比对。检出 Hit 时，若已有相同序号和频率的发送包，立刻比对。频率对不上当前正在听的这一对时，仍按解出的频率对和序号尝试匹配，匹配状态写「校验失败」。`phoneReceiveDate` 固定为这一包 Naiser 前导起点所在音频回调的绝对时间，不用样本偏移再推。这一包解调结束时再记一次当前绝对时间，作为 `demodEndDate`。

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

关键事件都写入该文件：开始发送、停止发送、当前频率对、发送时间戳、播放结束时间、音量 `outputVolume=0.xx`、错误信息。`WatchModel.stop()` 写「停止发送 原因=原始信息」。用户按停止按钮时原因是「用户按停止按钮」；收到手机 `.stop` 时原因是「收到手机停止指令」；`resignedFrontmost` 时原因是「resignedFrontmost rawValue=X」。其他调用写函数名和关键参数原值，不用归类后的中文代替原始值。手表上每个包的 `play` 返回后额外记一条「播放结束 序号 X 时间 ...」。这条和发送时间一样，先留在发送循环的内存里，循环结束后再一次性同步。日志只写在 Documents 里。发送循环里的日志先写入手表本地文件和内存数组 `pendingLogs`，不在循环内通过 Watch Connectivity 发送，避免打断播放节奏。状态变为「发送完成」或「已停止」之后，再一次性把这批日志发给 iPhone。手表端不提供日志查看界面。iPhone 上可在「日志」页、访达或「文件」App 里看。测试结束时，iPhone 把这次的原始麦克风采样写成 `Documents/AquaEcho_Recording_yyyyMMdd_HHmmss.wav`，32-bit float、单声道，采样率和录音回调一致。日志页列出 Documents 里的文件，并在这一栏放「一键清理」。它删除所有 `AquaEcho_Results_` 开头的 `.csv`、所有 `AquaEcho_Log_` 开头的 `.txt`，以及所有 `AquaEcho_Recording_` 开头的 `.wav`，完成后界面显示「已清理 CSV、日志和调试录音」。

iPhone 每处理完一个包写一条「包 X 前导对齐=是/否 解出=hex或空 通过=是/否 解调耗时=XXXms 解出序号=N或空 是否纠错=是/否 纠错后是否通过=是/否」。没有解出载荷时，解出和解出序号都写「空」。每攒满 146 个编码比特并译回 64 bit 再写一条「解调=成功/失败 解出低频=X或空 解出高频=X或空 解出序号=X或空 纠错=是/否 校验=通过/失败 解出hex=XXXXXXXXXXXXXXXX或空 耗时=XXXms 匹配=已匹配/无对应包/校验失败」，校验失败也写。未能攒满编码比特的不写这条。每秒写一条「检测峰值 SNR=X.X 能量比=X.X」。每个包结束时再写一条「包 X 结束后窗口剩余 XXXXX 样本」，剩余为 0 也写。

全部包发送完成，或用户在手表上停止之后，手表立刻发送 `kind` 为 `.finished` 的消息，不等日志同步。iPhone 一收到就停止录音，用已经实时算出的各包结果立刻写评分和 CSV，并把界面状态设为「测试完成」。这个状态只由结束消息驱动，不依赖日志是否已经到达，也不再等待事后分析。

每一行是一次发送，包含频率对、随机包的十六进制、序号、Watch 发送时间、iPhone 接收时间、解调结束时间、平均信噪比、双频能量比、通过率、三项得分和总分，以及「本包是否通过」（1 或 0）。另外有「解出低频」「解出高频」「解出序号」「是否纠错」。时间是各自设备的本地时间，并带时区偏移；发送和接收旁边还有 Unix 毫秒，方便事后对位。解调结束时间是维特比译码完成时的绝对时间。「是否纠错」为 1 表示译码改过至少一个编码比特。

## 自检

不连真机也可以核对相位连续性、Goertzel、评分边界和 CSV：

```bash
swiftc -O -o /tmp/aquaecho-selfcheck \
  Shared/PacketLayout.swift Shared/ExtendedHamming.swift Shared/ConvolutionalCode.swift \
  Shared/TestConfig.swift Shared/Models.swift Shared/Goertzel.swift \
  Shared/NaiserWaveform.swift Shared/OFDMModem.swift \
  Shared/Scoring.swift Shared/SignalAnalyzer.swift Shared/CSVExporter.swift \
  SelfCheck/main.swift
/tmp/aquaecho-selfcheck
```

通过时打印 `SELF_CHECK_OK`。
