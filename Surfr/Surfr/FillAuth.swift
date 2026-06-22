import Foundation

/// Pure decision for the in-browser fill auth gate (8e). Mirrors reveal/copy policy and guarantees the
/// "Use master password" path is never a dead end: whenever auth is required and biometric didn't
/// succeed (cancelled or unavailable), fall back to the master password.
enum FillAuth {
    /// True ⇒ present the master-password fallback; false ⇒ proceed with the fill directly.
    static func needsMasterFallback(requireAuth: Bool, biometricEnabled: Bool, biometricSucceeded: Bool) -> Bool {
        guard requireAuth else { return false }          // setting off → fill immediately
        return !(biometricEnabled && biometricSucceeded) // cancelled / no biometric → master fallback
    }
}
