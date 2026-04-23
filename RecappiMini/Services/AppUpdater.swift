import Combine
import Foundation
@preconcurrency import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    let updaterController: SPUStandardUpdaterController

    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var automaticallyDownloadsUpdates: Bool
    @Published private(set) var lastUpdateCheckDate: Date?

    private var didStartUpdater = false
    private var cancellables: Set<AnyCancellable> = []

    var updater: SPUUpdater { updaterController.updater }

    private override init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        let updater = updaterController.updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        self.lastUpdateCheckDate = updater.lastUpdateCheckDate

        super.init()

        observe(updater)
    }

    func start() {
        guard !didStartUpdater else { return }
        didStartUpdater = true
        updaterController.startUpdater()
        synchronizeFromUpdater()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ newValue: Bool) {
        guard updater.automaticallyChecksForUpdates != newValue else { return }
        updater.automaticallyChecksForUpdates = newValue
        synchronizeFromUpdater()
    }

    func setAutomaticallyDownloadsUpdates(_ newValue: Bool) {
        guard updater.automaticallyDownloadsUpdates != newValue else { return }
        updater.automaticallyDownloadsUpdates = newValue
        synchronizeFromUpdater()
    }

    private func observe(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyChecks in
                self?.automaticallyChecksForUpdates = automaticallyChecks
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] automaticallyDownloads in
                self?.automaticallyDownloadsUpdates = automaticallyDownloads
            }
            .store(in: &cancellables)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] lastCheckDate in
                self?.lastUpdateCheckDate = lastCheckDate
            }
            .store(in: &cancellables)
    }

    private func synchronizeFromUpdater() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}
