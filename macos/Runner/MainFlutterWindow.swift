import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var activationChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.title = "灯川 Rillight"
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "rillight/window_activation",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "activatePlayer" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let pid = arguments["pid"] as? Int,
            pid > 0, pid <= Int(Int32.max),
            let player = NSRunningApplication(processIdentifier: pid_t(pid)),
            !player.isTerminated else {
        result(false)
        return
      }
      // The user clicked Play in the host. Hand focus to that ready helper;
      // respect a later switch to another app while the helper was opening.
      if player.isActive {
        result(true)
      } else if !NSApp.isActive {
        result(false)
      } else if #available(macOS 14.0, *) {
        NSApp.yieldActivation(to: player)
        result(player.activate(from: NSRunningApplication.current,
                               options: [.activateAllWindows]))
      } else {
        result(player.activate(options: [.activateIgnoringOtherApps,
                                         .activateAllWindows]))
      }
    }
    activationChannel = channel

    super.awakeFromNib()
  }

  // Hide before first order-on-screen so startup hide/resize is not treated as
  // "last window closed". Player process still quits via last-window-closed.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
