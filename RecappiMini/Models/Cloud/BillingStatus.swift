import Foundation

enum BillingTier: String, CaseIterable, Codable, Equatable, Sendable {
    case free
    case starter
    case pro
    case business
    case unlimited

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .starter: return "Starter"
        case .pro: return "Pro"
        case .business: return "Business"
        case .unlimited: return "Unlimited"
        }
    }
}

struct BillingStatus: Decodable, Equatable, Sendable {
    let tier: BillingTier
    let periodStart: Date?
    let periodEnd: Date?
    let storageBytes: Int64
    let storageCapBytes: Int64
    let minutesUsed: Double
    let minutesCap: Double
    let isOverStorage: Bool
    let isOverMinutes: Bool

    enum CodingKeys: String, CodingKey {
        case tier
        case periodStart
        case periodEnd
        case storageBytes
        case storageCapBytes
        case minutesUsed
        case minutesCap
        case isOverStorage
        case isOverMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decode(BillingTier.self, forKey: .tier)
        periodStart = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .periodStart)
        periodEnd = RecappiDateDecoder.decodeDateIfPresent(from: container, forKey: .periodEnd)
        storageBytes = try container.decode(Int64.self, forKey: .storageBytes)
        storageCapBytes = try container.decodeIfPresent(Int64.self, forKey: .storageCapBytes) ?? 0
        minutesUsed = try container.decode(Double.self, forKey: .minutesUsed)
        minutesCap = try container.decodeIfPresent(Double.self, forKey: .minutesCap) ?? 0
        isOverStorage = try container.decode(Bool.self, forKey: .isOverStorage)
        isOverMinutes = try container.decode(Bool.self, forKey: .isOverMinutes)
    }

    var hasUnlimitedStorage: Bool {
        tier == .unlimited || storageCapBytes <= 0
    }

    var hasUnlimitedMinutes: Bool {
        tier == .unlimited || minutesCap <= 0
    }

    var effectiveIsOverStorage: Bool {
        !hasUnlimitedStorage && isOverStorage
    }

    var effectiveIsOverMinutes: Bool {
        !hasUnlimitedMinutes && isOverMinutes
    }

    var effectiveIsOverAnyLimit: Bool {
        effectiveIsOverStorage || effectiveIsOverMinutes
    }
}

struct BillingURLResponse: Decodable, Equatable, Sendable {
    let url: String
}

