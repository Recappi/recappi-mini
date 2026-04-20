import Foundation

enum ShellError: Error, CustomStringConvertible {
    case nonZeroExit(Int32, String)

    var description: String {
        switch self {
        case let .nonZeroExit(code, output):
            return "process exited with code \(code):\n\(output)"
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = Data(stdout.fileHandleForReading.readDataToEndOfFile())
        let error = Data(stderr.fileHandleForReading.readDataToEndOfFile())
        let combined = String(decoding: output + error, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ShellError.nonZeroExit(process.terminationStatus, combined)
        }

        return combined
    }
}
