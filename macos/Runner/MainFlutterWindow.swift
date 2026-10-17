import Cocoa
import CryptoKit
import FlutterMacOS
import UniformTypeIdentifiers
import window_manager

class MainFlutterWindow: NSWindow {
  private var activationChannel: FlutterMethodChannel?
  private var updateChannel: FlutterMethodChannel?
  private var updateExportPending = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.title = "灯川 Rillight"
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let updates = FlutterMethodChannel(
      name: "com.rillight/updates",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    updates.setMethodCallHandler { [weak self] call, result in
      guard call.method == "install" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(["status": "cancelled"])
        return
      }
      self.exportUpdate(call.arguments, result: result)
    }
    updateChannel = updates

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

  // The sandbox grants access only to the location the user chooses. Keep the
  // existing user-selected.read-write entitlement; never shell out to mount.
  private func exportUpdate(_ arguments: Any?, result: @escaping FlutterResult) {
    guard !updateExportPending,
          let args = arguments as? [String: Any],
          let path = args["path"] as? String,
          let name = args["name"] as? String,
          let hash = args["sha256"] as? String,
          let length = args["length"] as? NSNumber,
          length.int64Value > 0,
          hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          let bundleID = Bundle.main.bundleIdentifier,
          let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      result(["status": "failed", "failure": "invalidFile"])
      return
    }
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let root = cache.appendingPathComponent(bundleID)
      .appendingPathComponent("rillight-updates").resolvingSymlinksInPath()
    let session = source.deletingLastPathComponent()
    guard source.resolvingSymlinksInPath() == source,
          session.deletingLastPathComponent() == root,
          session.lastPathComponent.hasPrefix("session-"),
          source.lastPathComponent == name, source.pathExtension == "dmg" else {
      result(["status": "failed", "failure": "invalidFile"])
      return
    }
    updateExportPending = true
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [.diskImage]
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let destination = panel.url else {
        self?.updateExportPending = false
        result(["status": "cancelled"])
        return
      }
      let access = destination.startAccessingSecurityScopedResource()
      DispatchQueue.global(qos: .userInitiated).async {
        var failure: String?
        do {
          guard destination.standardizedFileURL != source,
                try Self.validUpdateFile(source, hash: hash, length: length.int64Value) else {
            throw UpdateExportError.invalidFile
          }
          // NSSavePanel already asks the user before replacing an existing file.
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: source, to: destination)
          guard try Self.validUpdateFile(destination, hash: hash, length: length.int64Value) else {
            throw UpdateExportError.invalidFile
          }
        } catch UpdateExportError.invalidFile {
          failure = "invalidFile"
        } catch {
          failure = "systemFailure"
        }
        let exportFailure = failure
        DispatchQueue.main.async {
          defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            self?.updateExportPending = false
          }
          if let failure = exportFailure {
            result(["status": "failed", "failure": failure])
          } else if NSWorkspace.shared.open(destination) {
            result(["status": "handedOff", "localPath": destination.path])
          } else {
            result(["status": "failed", "failure": "unavailable", "localPath": destination.path])
          }
        }
      }
    }
  }

  private enum UpdateExportError: Error { case invalidFile }

  private static func validUpdateFile(_ url: URL, hash: String, length: Int64) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          Int64(values.fileSize ?? -1) == length else { return false }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var digest = SHA256()
    var count: Int64 = 0
    while let bytes = try file.read(upToCount: 64 * 1024), !bytes.isEmpty {
      count += Int64(bytes.count)
      if count > length { return false }
      digest.update(data: bytes)
    }
    return count == length && digest.finalize().map { String(format: "%02x", $0) }.joined() == hash
  }

  // Hide before first order-on-screen so startup hide/resize is not treated as
  // "last window closed". Player process still quits via last-window-closed.
  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
