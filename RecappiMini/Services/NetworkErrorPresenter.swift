import Foundation

enum NetworkErrorPresenter {
    static func userFacingMessage(for error: Error) -> String {
        if let apiError = error as? RecappiAPIError {
            return userFacingMessage(for: apiError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "网络不可用，请检查连接后重试"
            case NSURLErrorTimedOut:
                return "连接超时，请稍后重试"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "无法连接 Recappi Cloud，请稍后重试"
            case NSURLErrorNetworkConnectionLost:
                return "网络连接中断，请稍后重试"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return "安全连接失败，请检查代理或网络设置"
            default:
                return "网络请求失败，请稍后重试"
            }
        }

        return userFacingMessage(rawMessage: error.localizedDescription, fallback: "操作失败，请稍后重试")
    }

    static func userFacingMessage(rawMessage: String?, fallback: String = "操作失败，请稍后重试") -> String {
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("socket is not connected")
            || lowercasedMessage.contains("socket not connected")
            || lowercasedMessage.contains("broken pipe")
            || lowercasedMessage.contains("connection reset")
            || lowercasedMessage.contains("connection refused")
            || lowercasedMessage.contains("network connection was lost")
            || lowercasedMessage.contains("enotconn")
            || lowercasedMessage.contains("econnreset")
            || lowercasedMessage.contains("econnrefused") {
            return "网络连接中断，请稍后重试"
        }
        if lowercasedMessage.contains("timed out")
            || lowercasedMessage.contains("timeout")
            || lowercasedMessage.contains("etimedout") {
            return "连接超时，请稍后重试"
        }
        if lowercasedMessage.contains("not connected to the internet")
            || lowercasedMessage.contains("offline") {
            return "网络不可用，请检查连接后重试"
        }
        if lowercasedMessage.contains("tls")
            || lowercasedMessage.contains("certificate")
            || lowercasedMessage.contains("ssl") {
            return "安全连接失败，请检查代理或网络设置"
        }
        return message.isEmpty ? fallback : message
    }

    static func userFacingMessage(for apiError: RecappiAPIError) -> String {
        switch apiError {
        case .invalidURL:
            return "Recappi Cloud 地址无效"
        case .invalidResponse:
            return "Recappi Cloud 返回了无效响应"
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .http(let statusCode, let message):
            switch statusCode {
            case 408:
                return "请求超时，请稍后重试"
            case 409:
                return message.isEmpty ? "当前操作暂时不可用" : message
            case 429:
                return "请求太频繁，请稍后重试"
            case 500...599:
                return "Recappi Cloud 暂时不可用，请稍后重试"
            default:
                return message.isEmpty ? "请求失败（\(statusCode)）" : message
            }
        }
    }
}
