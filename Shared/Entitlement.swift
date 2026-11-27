import Foundation
import Security

struct Entitlement: Codable, Equatable {
    var firstOpen = Date.now
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var lastSeen: Date?

    var trialStart: Date { min(proStartedAt ?? firstOpen, trialClaimedAt ?? .distantFuture) }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || max(now, lastSeen ?? now) < trialEnd
    }

    mutating func observe(_ now: Date, free: Bool) {
        if !free && proStartedAt == nil { proStartedAt = now }
        lastSeen = max(lastSeen ?? now, now)
    }

    mutating func mergeClock(_ other: Entitlement) {
        firstOpen = min(firstOpen, other.firstOpen)
        proStartedAt = [proStartedAt, other.proStartedAt].compactMap { $0 }.min()
        trialClaimedAt = [trialClaimedAt, other.trialClaimedAt].compactMap { $0 }.min()
        lastSeen = [lastSeen, other.lastSeen].compactMap { $0 }.max()
    }

    mutating func verifyPurchase(revoked: Bool) { purchasedPro = !revoked }

    mutating func verifyTrial(_ original: Date, revoked: Bool) {
        if !revoked { trialClaimedAt = min(trialClaimedAt ?? .distantFuture, original) }
    }
}

actor EntitlementVault {
    private let localKey = "moodcal.entitlement.v1"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.hgsldswk.moodcal",
         kSecAttrAccount as String: "entitlement.v1"]
    }

    func load() -> Entitlement? {
        let local = UserDefaults.standard.data(forKey: localKey).flatMap { try? JSONDecoder().decode(Entitlement.self, from: $0) }
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let secured = try? JSONDecoder().decode(Entitlement.self, from: data) else { return local }
        var combined = local ?? secured
        combined.mergeClock(secured)
        if let local, (secured.lastSeen ?? .distantPast) > (local.lastSeen ?? .distantPast) {
            combined.purchasedPro = secured.purchasedPro
        }
        return combined
    }

    func save(_ entitlement: Entitlement) {
        guard let data = try? JSONEncoder().encode(entitlement) else { return }
        UserDefaults.standard.set(data, forKey: localKey)
        let values = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(request as CFDictionary, nil)
        }
    }
}
