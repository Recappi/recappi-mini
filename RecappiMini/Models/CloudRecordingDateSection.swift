import Foundation

struct CloudRecordingDateSection: Identifiable {
    let id: String
    let title: String
    var recordings: [CloudRecording]
}
