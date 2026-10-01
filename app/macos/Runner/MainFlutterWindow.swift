import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var pointerLock: PointerLock?

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
    pointerLock = PointerLock(messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// First-person mouse look, like a browser's pointer lock (lib/interop/pointer_lock_io.dart): the
/// cursor is hidden and held in the middle of the window, and the mouse's movement goes to Dart as
/// deltas. Clicks land in the middle, where the crosshair is. It lets go when told to, and by itself
/// when you switch to another app.
final class PointerLock: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var locked = false
  private var monitor: Any?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "agent_office/pointer_lock", binaryMessenger: messenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "lock": self?.lock()
      case "unlock": self?.unlock()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(letGo), name: NSApplication.didResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(letGo), name: NSWindow.didResignKeyNotification, object: window)
  }

  private func lock() {
    guard !locked, let window = window, window.isKeyWindow else { return }
    locked = true
    // Into the middle of the window (Quartz counts y down from the top of the main screen).
    let frame = window.frame
    let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
    CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: top - frame.midY))
    CGAssociateMouseAndMouseCursorPosition(0)
    NSCursor.hide()
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    ) { [weak self] event in
      self?.channel.invokeMethod("move", arguments: [Double(event.deltaX), Double(event.deltaY)])
      return event
    }
    channel.invokeMethod("changed", arguments: true)
  }

  private func unlock() {
    guard locked else { return }
    locked = false
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    CGAssociateMouseAndMouseCursorPosition(1)
    NSCursor.unhide()
    channel.invokeMethod("changed", arguments: false)
  }

  @objc private func letGo() { unlock() }
}
