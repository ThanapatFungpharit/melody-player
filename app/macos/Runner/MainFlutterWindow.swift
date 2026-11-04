import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // MELODY_WINDOW_SIZE=390x844 opens the window at another size, such as a
    // phone's, while developing (see tools/dev/env.py).
    if let size = ProcessInfo.processInfo.environment["MELODY_WINDOW_SIZE"] {
      let parts = size.split(separator: "x").compactMap { Double($0) }
      if parts.count == 2 && parts.allSatisfy({ $0 > 0 }) {
        self.setContentSize(NSSize(width: parts[0], height: parts[1]))
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
