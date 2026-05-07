import Foundation

struct DevelopmentAuthStore {
    private let fileManager = FileManager.default

    private var fileURL: URL {
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

    func saveBearerToken(_ value: String) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("[Recappi] failed to persist debug auth token: \(error.localizedDescription)")
            return false
        }
    }

    func deleteBearerToken() -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return true }
        do {
            try fileManager.removeItem(at: fileURL)
            return true
        } catch {
            NSLog("[Recappi] failed to remove debug auth token: \(error.localizedDescription)")
            return false
        }
    }
}

