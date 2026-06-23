import Foundation

public struct RecappiCloudOriginResolver: Sendable {
    public static let defaultOrigin = "https://recordmeet.ing"

    private let environment: [String: String]
    private let appPreferenceReader: @Sendable (String) -> String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appPreferenceReader: @escaping @Sendable (String) -> String? = RecappiCloudOriginResolver.readAppPreference
    ) {
        self.environment = environment
        self.appPreferenceReader = appPreferenceReader
    }

    public func resolve(explicitOrigin: String? = nil) -> String {
        if let explicitOrigin, let normalized = Self.nonEmptyOrigin(explicitOrigin) {
            return normalized
        }

        for key in ["RECAPPI_BACKEND_URL", "RECAPPI_API_ORIGIN"] {
            if let normalized = Self.nonEmptyOrigin(environment[key]) {
                return normalized
            }
        }

        for key in ["recappi.backendOrigin", "backendBaseURL"] {
            if let normalized = Self.nonEmptyOrigin(appPreferenceReader(key)) {
                return normalized
            }
        }

        return Self.defaultOrigin
    }

    public static func normalizeOrigin(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private static func nonEmptyOrigin(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = normalizeOrigin(raw)
        return normalized.isEmpty ? nil : normalized
    }

    public static func readAppPreference(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, "com.recappi.mini" as CFString) as? String
    }
}

public struct RecappiCloudCredentialStore: Sendable {
    private let environment: [String: String]
    private let keychainReader: @Sendable () -> String?
    private let developmentReader: @Sendable () -> String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainReader: (@Sendable () -> String?)? = nil,
        developmentReader: (@Sendable () -> String?)? = nil
    ) {
        self.environment = environment
        self.keychainReader = keychainReader ?? Self.readKeychainBearerToken
        self.developmentReader = developmentReader ?? Self.readDevelopmentBearerToken
    }

    public func readBearerToken() -> String? {
        if let token = Self.normalizeBearerToken(environment["RECAPPI_AUTH_TOKEN"]) {
            return token
        }

        if environment["RECAPPI_USE_FILE_AUTH_STORAGE"] == "1",
           let token = Self.normalizeBearerToken(developmentReader()) {
            return token
        }

        if Self.isTruthy(environment["RECAPPI_DISABLE_KEYCHAIN_AUTH"]) {
            return nil
        }

        return Self.normalizeBearerToken(keychainReader())
    }

    public static func normalizeBearerToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("bearer ") {
            let suffix = trimmed.dropFirst("Bearer ".count)
            let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        if trimmed.lowercased().hasPrefix("set-auth-token:") {
            let suffix = trimmed.dropFirst("set-auth-token:".count)
            let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return trimmed
    }

    private static func isTruthy(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func readKeychainBearerToken() -> String? {
        KeychainTokenStore().readBearerToken()
    }

    private static func readDevelopmentBearerToken() -> String? {
        DevelopmentTokenStore().readBearerToken()
    }
}

public struct RecappiCloudAuth: Sendable {
    private let originResolver: RecappiCloudOriginResolver
    private let credentialStore: RecappiCloudCredentialStore

    public init(
        originResolver: RecappiCloudOriginResolver = RecappiCloudOriginResolver(),
        credentialStore: RecappiCloudCredentialStore = RecappiCloudCredentialStore()
    ) {
        self.originResolver = originResolver
        self.credentialStore = credentialStore
    }

    public func context(explicitOrigin: String? = nil) throws -> RecappiCloudAuthContext {
        guard let bearerToken = credentialStore.readBearerToken() else {
            throw RecappiCloudError.notSignedIn
        }
        return RecappiCloudAuthContext(
            origin: originResolver.resolve(explicitOrigin: explicitOrigin),
            bearerToken: bearerToken
        )
    }
}

private struct KeychainTokenStore: Sendable {
    private let service = "com.recappi.mini"
    private let account = "recappi.auth-token"
    private let timeoutSeconds: TimeInterval = 2

    func readBearerToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DevelopmentTokenStore: Sendable {
    private var fileURL: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("com.recappi.mini", isDirectory: true)
            .appendingPathComponent("debug-auth-token", isDirectory: false)
    }

    func readBearerToken() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
