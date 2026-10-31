import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var recordingActivity: RecordingActivityBridge?
  private var localNotifications: AgenoteLocalNotifications?
  private var inputMonitor: AudioInputMonitor?
  private var soniNoteBridge: SoniNoteBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    if let url = launchOptions?[.url] as? URL { RecordingActivityBridge.receive(url) }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AgenoteLocalNotifications") {
      localNotifications = AgenoteLocalNotifications(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AgenoteRecordingActivity") {
      recordingActivity = RecordingActivityBridge(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "YanShuSoniNote") {
      soniNoteBridge?.close()
      soniNoteBridge = SoniNoteBridge(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "YanShuAudioInput") {
      inputMonitor = AudioInputMonitor(messenger: registrar.messenger())
    }
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.notification.request.identifier.hasPrefix("agenote-actions:") {
      let account = response.notification.request.content.userInfo["owner"] as? String
      if let localNotifications = localNotifications { localNotifications.open(account) }
      else if let account = account, account == UserDefaults.standard.string(forKey: "agenote.notice.owner") {
        UserDefaults.standard.set(account, forKey: "agenote.notice.opened")
      }
      completionHandler()
    } else { super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler) }
  }
  deinit { soniNoteBridge?.close() }
}


/// Uses only Apple's local notification API; no APNs or vendor push registration.
private final class AgenoteLocalNotifications {
  private let channel: FlutterMethodChannel
  private let center = UNUserNotificationCenter.current()
  private let prefs = UserDefaults.standard
  private let prefix = "agenote-actions:"
  private var revision = 0
  private var owner: String? { prefs.string(forKey: "agenote.notice.owner") }
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agenote/local-notifications", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      let args = call.arguments as? [String: Any] ?? [:]
      let account = args["owner"] as? String
      switch call.method {
      case "configure":
        let enabled = args["enabled"] as? Bool ?? false
        let changed = self.owner != account
        self.prefs.set(account, forKey: "agenote.notice.owner")
        self.prefs.set(enabled, forKey: "agenote.notice.enabled")
        if changed { self.prefs.removeObject(forKey: "agenote.notice.opened") }
        if changed || !enabled { self.sync(ids: [], account: account, badge: 0) }
        result(nil)
      case "sync":
        if account == self.owner {
          self.sync(ids: args["ids"] as? [String] ?? [], account: account, badge: args["badge"] as? Int ?? 0)
        }
        result(nil)
      case "show":
        guard let account = account, account == self.owner,
              self.prefs.bool(forKey: "agenote.notice.enabled"), let id = args["id"] as? String else { result(false); return }
        let revision = self.revision
        self.center.getNotificationSettings { [weak self] settings in
          DispatchQueue.main.async {
            guard let self = self, self.owner == account, self.revision == revision,
                  self.prefs.bool(forKey: "agenote.notice.enabled"),
                  (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional), settings.alertSetting == .enabled else { result(false); return }
            let content = UNMutableNotificationContent()
            content.title = args["title"] as? String ?? "Agenote"
            content.body = args["body"] as? String ?? ""
            content.sound = args["silent"] as? Bool == true ? nil : .default
            content.badge = NSNumber(value: args["badge"] as? Int ?? 0)
            content.userInfo = ["owner": account]
            self.center.add(UNNotificationRequest(identifier: self.prefix + id, content: content, trigger: nil)) { error in
              DispatchQueue.main.async { result(error == nil) }
            }
          }
        }
      case "status":
        self.center.getNotificationSettings { settings in
          self.center.getDeliveredNotifications { delivered in
            let count = delivered.filter { $0.request.identifier.hasPrefix("agenote-actions:") }.count
            let granted = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) && settings.alertSetting == .enabled
            let ids = delivered.map { $0.request.identifier }.filter { $0.hasPrefix(self.prefix) }.map { String($0.dropFirst(self.prefix.count)) }
            DispatchQueue.main.async { result(["permissionGranted": granted, "activeCount": count, "activeIds": ids]) }
          }
        }
      case "takeOpen":
        result(self.prefs.string(forKey: "agenote.notice.opened"))
        self.prefs.removeObject(forKey: "agenote.notice.opened")
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func sync(ids: [String], account: String?, badge: Int) {
    revision += 1
    let currentRevision = revision
    let keep = Set(ids.map { prefix + $0 })
    center.getDeliveredNotifications { [weak self] delivered in
      guard let self = self else { return }
      DispatchQueue.main.async {
        guard self.owner == account, self.revision == currentRevision else { return }
        self.center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(self.prefix) && !keep.contains($0) })
        UIApplication.shared.applicationIconBadgeNumber = badge
      }
    }
    center.getPendingNotificationRequests { [weak self] requests in
      guard let self = self else { return }
      DispatchQueue.main.async {
        guard self.owner == account, self.revision == currentRevision else { return }
        self.center.removePendingNotificationRequests(withIdentifiers: requests.map { $0.identifier }.filter { $0.hasPrefix(self.prefix) && !keep.contains($0) })
      }
    }
  }
  func open(_ account: String?) {
    guard let account = account, account == owner, prefs.bool(forKey: "agenote.notice.enabled") else { return }
    prefs.set(account, forKey: "agenote.notice.opened")
    channel.invokeMethod("opened", arguments: account)
  }
}
