import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var source: String
        var status: String
        var transcription: String
        var capturing: Bool
        var elapsedSeconds: Int
        var sampledAt: Date
        var details: [String: String]?
        var timerAnchor: Date { sampledAt.addingTimeInterval(-Double(elapsedSeconds)) }
    }
    var meetingId: String
}
