import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // The office wants room: open at 1440x900 (or most of a smaller screen), centred, and never
    // so small that the HUD's top bar has to wrap into the scene.
    let visible = self.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1440, visible.width * 0.9), height: min(900, visible.height * 0.9))
    self.setContentSize(size)
    self.contentMinSize = NSSize(width: 800, height: 560)
    self.title = "Agent Office"
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
