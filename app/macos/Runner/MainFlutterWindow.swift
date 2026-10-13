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
    registerAppIcon(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Shows the icon Dart draws for the saved accent color in the Dock while
  // Melody runs; the bundle's own icon stays as built.
  private func registerAppIcon(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "melody/app_icon", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "setImages",
        let images = call.arguments as? [AnyHashable: Any],
        let png = images.values.compactMap({ $0 as? FlutterStandardTypedData }).first,
        let image = NSImage(data: png.data)
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSApp.applicationIconImage = image
      result(nil)
    }
  }
}
