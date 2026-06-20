import Foundation
import Security

/// Small Keychain glue for the biometric door. All vault keychain items use the **data-protection
/// keychain** (`kSecUseDataProtectionKeychain`) so macOS honours access groups + `ThisDeviceOnly`
/// accessibility the same way iOS does — important for sharing with the AutoFill extension later.
enum Keychain {
    /// The bare access-group suffix added in Xcode's Keychain Sharing capability. The real group is
    /// team-prefixed (`<AppIdentifierPrefix>.com.zeviter.surfr.vault`); we resolve the full value at
    /// runtime so no Team ID is hardcoded or committed.
    static let accessGroupSuffix = "com.zeviter.surfr.vault"

    /// The full, team-prefixed access group, resolved once. `nil` if resolution fails (e.g. the
    /// capability isn't present), in which case callers omit `kSecAttrAccessGroup` and fall back to
    /// the app's default group.
    static let accessGroup: String? = resolveAccessGroup()

    private static func resolveAccessGroup() -> String? {
        // Probe: add (or read) a throwaway generic-password item with no explicit access group. It
        // lands in our default keychain group; reading back its access group yields the team prefix.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zeviter.surfr.accessgroup.probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        var read = base
        read[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        var status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = base
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess { status = SecItemCopyMatching(read as CFDictionary, &result) }
        }

        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first
        else { return nil }

        return "\(prefix).\(accessGroupSuffix)"
    }

    /// Add `kSecAttrAccessGroup` to a query when we resolved one (otherwise rely on the default group).
    static func withAccessGroup(_ query: [String: Any]) -> [String: Any] {
        guard let accessGroup else { return query }
        var q = query
        q[kSecAttrAccessGroup as String] = accessGroup
        return q
    }
}
