import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var playerProcesses: PlayerProcesses?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.title = "灯川 Rillight"
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    playerProcesses = PlayerProcesses(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  // Hide before first order-on-screen so startup hide/resize is not treated as
  // "last window closed". Player process still quits via last-window-closed.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

// Keep the NSRunningApplication objects so a reused PID cannot redirect a
// termination request to an unrelated application.
private class PlayerProcesses {
  private let channel: FlutterMethodChannel
  private var children: [pid_t: NSRunningApplication] = [:]
  private var terminationObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "rillight/player_process", binaryMessenger: messenger)
    terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self = self,
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        self.children[app.processIdentifier] == app else { return }
      self.channel.invokeMethod("exited", arguments: Int(app.processIdentifier))
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "launch":
        guard let args = call.arguments as? [String: Any],
          let payload = args["payloadPath"] as? String,
          (payload as NSString).isAbsolutePath,
          let environment = args["environment"] as? [String: String] else {
          result(FlutterError(code: "invalid-launch", message: "Missing player launch data", details: nil))
          return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["player", payload]
        configuration.environment = environment
        // Direct posix_spawn of this sandbox-signed executable is not a valid
        // sandbox-inheriting helper. Launch the app through LaunchServices.
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) {
          app, error in
          DispatchQueue.main.async {
            guard let app = app else {
              result(FlutterError(code: "player-launch", message: error?.localizedDescription,
                                  details: nil))
              return
            }
            let pid = app.processIdentifier
            self.children[pid] = app
            result(Int(pid))
            // The termination notification can precede the launch completion.
            if app.isTerminated {
              self.channel.invokeMethod("exited", arguments: Int(pid))
            }
          }
        }
      case "terminate", "release":
        guard let value = call.arguments as? NSNumber else {
          result(FlutterError(code: "invalid-pid", message: "Missing player PID", details: nil))
          return
        }
        let pid = pid_t(value.int32Value)
        guard let app = self.children[pid] else {
          result(nil)
          return
        }
        if call.method == "release" {
          guard app.isTerminated else {
            result(FlutterError(code: "player-running", message: "Player is still running", details: nil))
            return
          }
          self.children.removeValue(forKey: pid)
        } else if app.isTerminated {
          self.channel.invokeMethod("exited", arguments: Int(pid))
        } else if !app.forceTerminate() {
          result(FlutterError(code: "player-terminate", message: "Player did not terminate", details: nil))
          return
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let observer = terminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    channel.setMethodCallHandler(nil)
  }
}
