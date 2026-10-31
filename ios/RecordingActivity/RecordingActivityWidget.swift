import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecordingActivityBundle: WidgetBundle {
    var body: some Widget { RecordingActivityWidget() }
}

struct RecordingActivityWidget: Widget {
    private let blue = Color(red: 6/255, green: 92/255, blue: 1)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "mic.fill").font(.title2).foregroundColor(blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agenote · " + (stale(context) ? "状态待核实" : context.state.status)).font(.headline)
                    Text(context.state.source).font(.subheadline).lineLimit(1)
                    if let battery = context.state.details?["battery"] { Text("电量 " + battery).font(.caption).foregroundColor(blue) }
                    Text(stale(context) ? "打开 App 核对当前录音" : context.state.transcription).font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                RecordingTimer(state: context.state, stale: stale(context)).font(.system(.title3, design: .monospaced)).foregroundColor(blue)
            }
            .padding(16)
            .activityBackgroundTint(Color.white)
            .activitySystemActionForegroundColor(blue)
            .widgetURL(link(context.attributes.meetingId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Agenote", systemImage: "mic.fill").foregroundColor(blue) }
                DynamicIslandExpandedRegion(.trailing) { RecordingTimer(state: context.state, stale: stale(context)).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stale(context) ? "状态待核实" : context.state.status).font(.headline)
                        Text(context.state.source).font(.subheadline).lineLimit(1)
                        if let details = context.state.details {
                            HStack(spacing: 12) {
                                if let battery = details["battery"] { Label(battery, systemImage: "battery.100") }
                                if let audio = details["audio"] { Text(audio) }
                            }.font(.caption).foregroundColor(blue)
                            if let storage = details["storage"] { Text("存储 " + storage).font(.caption) }
                            if let firmware = details["firmware"] { Text("固件 " + firmware).font(.caption) }
                        }
                        Text(stale(context) ? "打开 App 核对当前录音" : context.state.transcription).font(.caption).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: stale(context) ? "questionmark.circle" : "mic.fill").foregroundColor(blue)
            } compactTrailing: {
                RecordingTimer(state: context.state, stale: stale(context)).font(.caption2).monospacedDigit().frame(maxWidth: 56)
            } minimal: {
                Image(systemName: stale(context) ? "questionmark.circle" : "mic.fill").foregroundColor(blue)
            }
            .widgetURL(link(context.attributes.meetingId))
            .keylineTint(blue)
        }
    }
    private func stale(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Bool {
        if #available(iOS 16.2, *) { return context.isStale }
        return false
    }
    private func link(_ id: String) -> URL? {
        var url = URLComponents(); url.scheme = "agenote"; url.host = "recording"; url.path = "/" + id
        return url.url
    }
}

private struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        if stale { Text("待核实") }
        else if state.capturing {
            if #available(iOS 16.2, *) { Text(state.timerAnchor, style: .timer) }
            else { Text(String(format: "%02d:%02d", state.elapsedSeconds/60, state.elapsedSeconds%60)) }
        }
        else { Text(String(format: "%02d:%02d", state.elapsedSeconds/60, state.elapsedSeconds%60)) }
    }
}
