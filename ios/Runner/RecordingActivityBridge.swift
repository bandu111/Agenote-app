import Flutter
import UIKit
import ActivityKit
import UserNotifications

/// ActivityKit owns external layout. All updates here are local (pushType: nil).
final class RecordingActivityBridge {
    static weak var current: RecordingActivityBridge?
    static var pendingMeeting: String?
    private let channel: FlutterMethodChannel
    private var work: Task<Void, Never>?
    private var lastSequence: Int64 = 0
    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "agenote/recording_activity", binaryMessenger: messenger)
        Self.current = self
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            if call.method == "takeOpenMeeting" {
                result(Self.pendingMeeting); Self.pendingMeeting = nil; return
            }
            if call.method == "requestNotifications" { result(nil); return } // No notification permission required for ActivityKit.
            if call.method == "permissionSettings" {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    var data: [String: Any] = [:]
                    if #available(iOS 16.1, *) {
                        data["liveActivitiesSupported"] = true
                        data["liveActivitiesAllowed"] = ActivityAuthorizationInfo().areActivitiesEnabled
                    }
                    if settings.lockScreenSetting != .notSupported {
                        data["lockScreenAllowed"] = settings.lockScreenSetting == .enabled
                    }
                    let response = data
                    DispatchQueue.main.async { result(response) }
                }
                return
            }
            if call.method == "openNotificationSettings" || call.method == "requestLiveUpdates" {
                var address = UIApplication.openSettingsURLString
                if call.method == "openNotificationSettings" {
                    if #available(iOS 16.0, *) { address = UIApplication.openNotificationSettingsURLString }
                }
                guard let url = URL(string: address) else { result(false); return }
                UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
                return
            }
            if call.method == "capabilities" { result(self.capabilities()); return }
            guard call.method == "sync" else { result(FlutterMethodNotImplemented); return }
            let previous = self.work
            let data = call.arguments as? [String: Any]
            self.work = Task { @MainActor [weak self] in
                await previous?.value
                guard let self = self else { result(nil); return }
                do {
                    if #available(iOS 16.1, *) { try await self.sync(data) }
                    result(self.capabilities())
                } catch {
                    result(FlutterError(code: "live_activity_unavailable", message: "实时活动不可用，App 内入口仍可使用", details: nil))
                }
            }
        }
    }
    private func capabilities() -> [String: Any] {
        if #available(iOS 16.1, *) {
            return ["platform": "ios", "liveActivitiesAllowed": ActivityAuthorizationInfo().areActivitiesEnabled,
                    "activeCount": Activity<RecordingActivityAttributes>.activities.count,
                    "dynamicIsland": "systemDetermined"]
        }
        return ["platform": "ios", "liveActivitiesAllowed": false, "dynamicIsland": "unavailable"]
    }
    @available(iOS 16.1, *) @MainActor
    private func sync(_ data: [String: Any]?) async throws {
        let activities = Activity<RecordingActivityAttributes>.activities
        if data?["state"] as? String == "processing" {
            for activity in activities { await activity.end(using: nil, dismissalPolicy: .immediate) }
            return
        }
        guard let data = data else {
            for activity in activities { await activity.end(using: nil, dismissalPolicy: .immediate) }
            return
        }
        guard let id = data["meetingId"] as? String,
              id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let sequence = (data["sequence"] as? NSNumber)?.int64Value else { return }
        guard sequence > lastSequence else { return }; lastSequence = sequence
        let capturing = data["capturing"] as? Bool ?? false
        let elapsed = max(0, min((data["elapsedMs"] as? NSNumber)?.intValue ?? 0, 172800000))/1000
        let state = RecordingActivityAttributes.ContentState(
            source: String((data["sourceLabel"] as? String ?? "麦克风").prefix(60)),
            status: String((data["stateLabel"] as? String ?? "状态待核实").prefix(30)),
            transcription: String((data["transcription"] as? String ?? "").prefix(40)),
            capturing: capturing, elapsedSeconds: elapsed, sampledAt: Date(),
            details: (data["details"] as? [String: String])?.filter { ["audio", "battery", "storage", "firmware"].contains($0.key) }
                .mapValues { String($0.prefix(80)) })
        for activity in activities where activity.attributes.meetingId != id {
            await activity.end(using: nil, dismissalPolicy: .immediate)
        }
        let matching = activities.filter { $0.attributes.meetingId == id }
        for duplicate in matching.dropFirst() { await duplicate.end(using: nil, dismissalPolicy: .immediate) }
        if let activity = matching.first {
            if #available(iOS 16.2, *) { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))) }
            else { await activity.update(using: state) }
        } else if capturing && ActivityAuthorizationInfo().areActivitiesEnabled {
            if #available(iOS 16.2, *) {
                _ = try Activity.request(attributes: RecordingActivityAttributes(meetingId: id),
                    content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)), pushType: nil)
            } else {
                _ = try Activity.request(attributes: RecordingActivityAttributes(meetingId: id), contentState: state, pushType: nil)
            }
        }
    }
    @discardableResult static func receive(_ url: URL) -> Bool {
        guard url.scheme == "agenote", url.host == "recording", url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return false }
        let id = url.lastPathComponent
        guard id.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil else { return false }
        pendingMeeting = id
        current?.channel.invokeMethod("openMeeting", arguments: id)
        return true
    }
    deinit { channel.setMethodCallHandler(nil) }
}
