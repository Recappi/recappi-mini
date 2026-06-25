import Foundation

private let protocolVersion = 1
private let sidecarName = "recappi-mini-sidecar"
private let sidecarVersion = ProcessInfo.processInfo.environment["RECAPPI_SIDECAR_VERSION"] ?? "0.1.0"
private let unsupportedMessage = "Bundled Recappi Mini sidecar is installed, but native recording capture is not implemented in this helper build yet."

@discardableResult
private func writeJSON(_ value: [String: Any]) -> Bool {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let line = String(data: data, encoding: .utf8)
    else {
        return false
    }
    print(line)
    fflush(stdout)
    return true
}

private func result(id: Any, _ value: [String: Any]) {
    writeJSON([
        "jsonrpc": "2.0",
        "id": id,
        "result": value,
    ])
}

private func error(id: Any, code: Int, message: String, data: [String: Any]? = nil) {
    var error: [String: Any] = [
        "code": code,
        "message": message,
    ]
    if let data {
        error["data"] = data
    }
    writeJSON([
        "jsonrpc": "2.0",
        "id": id,
        "error": error,
    ])
}

private func readyEvent() {
    writeJSON([
        "jsonrpc": "2.0",
        "method": "recappi.event",
        "params": [
            "type": "ready",
            "protocolVersion": protocolVersion,
            "sidecar": [
                "name": sidecarName,
                "version": sidecarVersion,
            ],
        ],
    ])
}

private func requestID(from object: [String: Any]) -> Any {
    object["id"] ?? NSNull()
}

private func method(from object: [String: Any]) -> String? {
    object["method"] as? String
}

readyEvent()

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any]
    else {
        continue
    }

    let id = requestID(from: object)
    switch method(from: object) {
    case "recappi.handshake":
        result(id: id, [
            "protocolVersion": protocolVersion,
            "sidecar": [
                "name": sidecarName,
                "version": sidecarVersion,
            ],
            "capabilities": [],
        ])
    case "recappi.recording.status":
        let params = object["params"] as? [String: Any]
        result(id: id, [
            "sessionId": params?["sessionId"] as? String ?? "none",
            "state": "idle",
        ])
    case "recappi.recording.start":
        error(
            id: id,
            code: -32010,
            message: unsupportedMessage,
            data: [
                "capability": "recording.capture",
                "supported": false,
            ]
        )
    case "recappi.recording.stop", "recappi.recording.cancel":
        let params = object["params"] as? [String: Any]
        result(id: id, [
            "sessionId": params?["sessionId"] as? String ?? "none",
            "state": "cancelled",
        ])
    default:
        error(
            id: id,
            code: -32601,
            message: "Unknown Recappi sidecar method.",
            data: ["method": method(from: object) ?? ""]
        )
    }
}
