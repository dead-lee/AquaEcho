# AquaEcho

测试 Apple Watch 扬声器到 iPhone 麦克风的单向声波信道。场景是潜水时的短距离传信：寻找人耳几乎听不到、但在空气、水或塑料壳里仍然比较稳的频率组合。

## 两端

- **AquaEchoWatch**：发送端。按最大可用音量播放测试信号，并记下每次发送的本地时间。
- **AquaEcho**：接收端。用 48 kHz、`playAndRecord` + `measurement`（关闭自动增益）录音，用 Goertzel 测两个目标频率的能量和信噪比，按固定标准打 0–100 分。
- 配置通过 Watch Connectivity 从 iPhone 同步到 Watch。下次打开手表会沿用上次配置。

## 两种信号

1. **自定义 CPFSK**：两个频率分别代表 0 和 1，切换时相位连续。载荷是新生成的随机 8 字节，前面另有 `0xAA 0x55` 同步头。
2. **ggwave**：通过 Swift Package Manager 集成 [ggwave-spm](https://github.com/ggerganov/ggwave-spm)。使用超声协议，并按步进改起始频率。同样发送随机 8 字节，重复多次。ggwave 自带 Reed-Solomon。

默认扫描 15.0–20.0 kHz，步进 500 Hz。CPFSK 的两个音至少相隔 1 kHz。

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
2. 把 iPhone App 装到手机上，Watch App 会一起装上。测试时两边都留在前台。
3. 在 iPhone 上设好频率、步进、重复次数，点「同步到 Watch」，再点「开始测试」。
4. 把手表扬声器靠近 iPhone 底部麦克风。系统音量要用数码表冠调到最大；程序会把波形推到不失真的满幅。ggwave 多音如果直接用音量 100 会削波，所以编码幅度上限是 50，播之前再归一化到峰值 0.98。

模拟器没有这条真实声路，评分要在真机上做。

## CSV

每次测试结束会写入：

`Documents/AquaEcho_Results_yyyyMMdd_HHmmss.csv`

用数据线把 iPhone 连到 Mac，在访达侧边栏打开这台 iPhone 里的 AquaEcho，把 CSV 拖到桌面。`Info.plist` 里已经打开 `UIFileSharingEnabled` 和 `LSSupportsOpeningDocumentsInPlace`。

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
