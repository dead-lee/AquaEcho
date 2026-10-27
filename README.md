# AquaEcho

> 代码修改的权威设计见 [`docs/DESIGN.md`](docs/DESIGN.md)；任何改动前先更新设计并按其 review。

用水下手表扬声器向 iPhone 麦克风**单向**发送 64 bit 测试包，在空气、空气+密封袋、水下+密封袋三种场景下找最稳的频谱集合。

## 设计

- **单向**：手表只播放，手机只录音；没有 probe、没有 feedback、没有握手、没有重传。
- **场景**：手机端选择“空气 / 空气 + 密封袋 / 水下 + 密封袋”，场景会写进日志、CSV 和 WAV 文件名。
- **频谱集合**：S0–S6 共 7 组，覆盖 0.5–8 kHz；每组是一组 50 Hz 间隔的子载波，K 从 20 到 150。集合可以是非连续的，后续按实测结果挑子载波。
- **帧**：30 ms 公共 400 Hz 标记音 + 10 ms 保护间隔 + OFDM 训练符号 + S 个数据符号（每符号 20 ms + 5 ms 循环前缀）+ 20 ms 尾静音。单包 airtime 110–285 ms。
- **载荷**：64 bit = 8 bit 集合号 + 16 bit 包序号 + 40 bit SplitMix64 伪随机数。手机端按同样规则重建 64 bit 并逐 bit 比对；不需要 CRC，也不需要手表回传发送内容。
- **调制**：沿用 watercomms 的差分 BPSK-OFDM 思路（训练符号做单抽头均衡，数据符号相对前一个符号解相位），但同步改为标记音，去掉了 Naiser 前导和握手，参数按手表+防水袋重新选。
- **手表 UI**：WatchKit storyboard + `WKInterfaceVolumeControl`；表冠调系统音量，系统 HUD 是唯一音量反馈；手指滚动页面。
- **分析**：手机实时解码：音频回调进入滚动缓冲 → 检测 400 Hz 标记音 → 单帧解调 → 维特比译码 → 自校验 → 结果页随包更新；停止时只落盘 WAV/CSV，不再事后分析。

## 运行

1. iPhone 打开 AquaEcho；App 启动后会唤起手表并建立 workout 会话。
2. iPhone 选场景、距离/备注，点“开始测试”；手机若连接尚未就绪，会把开始指令排队，手表 ready/连接恢复后自动补发，不需要在手表上点开始。手表收到后发波，有 3 秒准备时间。
3. 手表不提供开始/停止按钮；开始和停止都从 iPhone 控制。
4. 手表端先点“**调节音量**”，再转表冠调系统音量；系统原生 HUD 是唯一音量条。手指负责滑动页面。
5. 扫描完成后手机会自动停止；结果页看总体通过率和每个集合的成功率。

手表不录音，不需要麦克风权限；手机需要麦克风权限。场景配置通过 WatchConnectivity 同步给手表；水下没有蓝牙，配置只在开始前同步。

手表的 workout 会话负责前台保活：扫描完成不结束；手机或手表 App 被切到后台时结束。手表切后台会结束会话，避免抬腕反复回到 App。

## 输出

- `AquaEcho_Scan_<场景>_*.csv`：每包一行，含场景、距离、备注、集合、K、包号、期望/解出 hex、通过、SNR、标记 SNR、airtime、时间。
- `AquaEcho_Scan_<场景>_*.wav`：原始录音，可离线复盘。
- `AquaEcho_ScanLog_<场景>_*.txt`：实时解码汇总与缺失包日志。
- `AquaEcho_Log_*.txt`：两端运行日志；手表日志按 8 KB 分块同步到手机。

日志里会明确写出场景、距离、集合、包号、期望载荷、解出载荷和是否通过，方便直接定位是“没收到”“收到但比特错”还是“集合不适合”。

停止流程会记录 `capture.stop / receiver.cancel / buffer.snapshot / receiver.finish / 写盘` 各阶段；停止后积压的 ingest 直接丢弃，不再继续解调。如果主线程超过 2 秒未响应，后台 watchdog 会写 `[Phone][Main]`。UI 日志按 0.2 秒合流，避免每条 Scan 日志都触发主线程刷新。

手机点开始后立即监听并 best-effort 发送一次 start；连接可达用 sendMessage，不可达用 transferUserInfo 排队，不等待 ready/active/ack。手表收到 start 立即发波，收到 stop 立即停止。停止时 receiver.cancel 立即返回，capture.stop 放后台。静音/0/140 也是有效测试结果。

启动日志会记录 `watchReady / activated / reachable / pendingStart` 和每次 `start` 的发送原因、返回值；workout 启动日志会记录 `source` 和 `appState`，App 在后台时不会尝试启动 workout。

手机“日志”页最上面有**一键清理扫描文件**；它会删除所有扫描 WAV/CSV/ScanLog 和所有 `AquaEcho_Log_*.txt`，并关闭日志句柄，下一次开始测试时才重新创建日志。

## 构建与安装

- iPhone 和手表分别用 `AquaEcho` / `AquaEchoWatch` scheme 构建。
- 纯逻辑回归测试：`swift test --scratch-path /tmp/AquaEchoTestsBuild`；覆盖 start 并发、start 重发、后台 workout 策略、日志合流、停止异步。
- 真机安装用 `Scripts/install-devices.sh`；手机和手表都做覆盖安装，不为了推手表包卸载手机，避免清掉已有权限。
- 手机安装后等待手表推送；仍失败时直接覆盖安装手表 App，并重试。只有持续无法安装时才考虑完整重装；完整重装会重新申请权限并可能清掉 Documents。

## 目标

80% 的包完全正确即可；偶尔丢包不是问题。先跑 20 包/组做快筛，再对最好的 2 组做 50 包精确统计。
