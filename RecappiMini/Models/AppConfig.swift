import Foundation
import SwiftUI

@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @AppStorage("backendBaseURL") var backendBaseURL: String = "https://recordmeet.ing"
    @AppStorage("cloudEnabled") var cloudEnabled: Bool = true

    @AppStorage("speechLanguage") var cloudLanguage: String = "en-US"

    var effectiveBackendBaseURL: String {
        let override = UITestModeConfiguration.shared.backendURL?.trimmingCharacters(in: .whitespaces)
        if let override, !override.isEmpty { return override }
        let trimmed = backendBaseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "https://recordmeet.ing" : trimmed
    }

    var normalizedCloudLanguage: String {
        let trimmed = cloudLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = trimmed.split(separator: "-").first, !base.isEmpty {
            return String(base)
        }
        return "en"
    }

    private init() {}
}
