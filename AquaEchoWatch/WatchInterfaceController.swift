import WatchKit

final class WatchInterfaceController: WKInterfaceController {
    @IBOutlet weak var volumeControl: WKInterfaceVolumeControl!

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        print("Stage1 WatchKit controller awake")
    }

    override func willActivate() {
        super.willActivate()
        volumeControl.focus()
        print("Stage1 volume control focused")
    }

    override func didDeactivate() {
        volumeControl.resignFocus()
        super.didDeactivate()
    }
}
