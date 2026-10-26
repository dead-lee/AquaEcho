import Combine
import SwiftUI
import WatchKit

@MainActor
final class WatchInterfaceController: WKInterfaceController {
    @IBOutlet private weak var titleLabel: WKInterfaceLabel!
    @IBOutlet private weak var foregroundLabel: WKInterfaceLabel!
    @IBOutlet private weak var reachableLabel: WKInterfaceLabel!
    @IBOutlet private weak var runLabel: WKInterfaceLabel!
    @IBOutlet private weak var setsLabel: WKInterfaceLabel!
    @IBOutlet private weak var statusLabel: WKInterfaceLabel!
    @IBOutlet private weak var progressLabel: WKInterfaceLabel!
    @IBOutlet private weak var volumeLabel: WKInterfaceLabel!
    @IBOutlet private weak var volumeControl: WKInterfaceVolumeControl!
    @IBOutlet private weak var volumeHintLabel: WKInterfaceLabel!

    private var model: WatchModel!
    private var cancellable: AnyCancellable?

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        model = WatchModel()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }
        render()
    }

    override func willActivate() {
        super.willActivate()
        model.noteScenePhase(.active)
        model.prepareAudioSession()
        model.refreshOutputVolume()
        render()
        scheduleVolumeFocus()
    }

    override func didDeactivate() {
        volumeControl.resignFocus()
        super.didDeactivate()
    }

    @IBAction private func focusVolume() {
        volumeControl.focus()
        print("Stage3 volume focus requested by button")
    }

    private func scheduleVolumeFocus() {
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.volumeControl.focus()
                print("Stage3 volume auto-focus after \(delay)s")
            }
        }
    }

    private func render() {
        guard let model, titleLabel != nil else { return }
        titleLabel.setText("AquaEcho 构建 \(AppBuild.number)")
        foregroundLabel.setText(model.foregroundRunning ? "前台保持中" : model.foregroundStatus)
        reachableLabel.setText(model.reachable ? "iPhone 已连接" : "iPhone 未连接")
        runLabel.setText(model.runLabel)
        setsLabel.setText("\(model.sets.map(\.id).joined(separator: ",")) · \(model.packetsPerSet) 包/组 · 共 \(model.totalPackets) 包")
        statusLabel.setText(model.status)
        progressLabel.setText(model.progressText)
        volumeLabel.setText("系统音量 \(Int((model.outputVolume * 100).rounded()))%")
        volumeHintLabel.setText("先点“调节音量”，再转表冠；手指滑动页面。")
    }
}
