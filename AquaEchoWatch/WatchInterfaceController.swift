import WatchKit

final class WatchInterfaceController: WKInterfaceController {
    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        print("Stage0 WatchKit controller awake")
    }

    override func willActivate() {
        super.willActivate()
        print("Stage0 WatchKit controller active")
    }
}
