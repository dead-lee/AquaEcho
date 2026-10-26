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
        volumeControl.focus()
    }

    override func didDeactivate() {
        volumeControl.resignFocus()
        super.didDeactivate()
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
    }
}
