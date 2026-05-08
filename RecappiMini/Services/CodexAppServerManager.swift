import AppKit
import Combine
import Foundation

@MainActor
final class CodexAppServerManager: ObservableObject {
    static let shared = CodexAppServerManager()

    enum State: Equatable {
        case stopped
        case starting
        case running(socketPath: String)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .stopped

    private let config = AppConfig.shared
    private var cancellable: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var process: Process?
    private var socketDirectory: URL?

    private init() {}

    func startObserving() {
        guard cancellable == nil else { return }
        cancellable = config.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncWithPreference()
                }
            }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
        syncWithPreference()
    }

    func syncWithPreference() {
        if config.experimentalCodexRealtimeEnabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    func startIfNeeded() {
        switch state {
        case .running, .starting:
            return
        case .stopped, .failed:
            start()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        socketDirectory = nil
        state = .stopped
    }

    private func start() {
        state = .starting

        let codexPath = ProcessInfo.processInfo.environment["RECAPPI_CODEX_CLI_PATH"] ?? "/opt/homebrew/bin/codex"
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            state = .failed("Codex CLI was not found at \(codexPath).")
            return
        }

        let shortID = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("rcx-\(shortID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            state = .failed("Could not create Codex app-server socket directory.")
            return
        }

        let socketPath = directory.appendingPathComponent("s.sock").path
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "unix://\(socketPath)"]
        process.environment = codexEnvironment(codexPath: codexPath)
        process.standardOutput = Pipe()
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.process === process else { return }
                self.process = nil
                if let socketDirectory = self.socketDirectory {
                    try? FileManager.default.removeItem(at: socketDirectory)
                }
                self.socketDirectory = nil
                if self.config.experimentalCodexRealtimeEnabled {
                    let message = Self.errorMessage(from: stderr) ?? "Codex app-server exited."
                    self.state = .failed(message)
                } else {
                    self.state = .stopped
                }
            }
        }

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            state = .failed("Could not start Codex app-server: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.socketDirectory = directory
        state = .running(socketPath: socketPath)
    }

    private func codexEnvironment(codexPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let codexDirectory = URL(fileURLWithPath: codexPath).deletingLastPathComponent().path
        let searchPaths = [
            codexDirectory,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (searchPaths + existingPath.split(separator: ":").map(String.init))
            .removingDuplicates()
            .joined(separator: ":")
        return environment
    }

    private static func errorMessage(from pipe: Pipe) -> String? {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
