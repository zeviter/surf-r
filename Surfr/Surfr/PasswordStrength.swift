import Foundation

/// A **soft** master-password strength hint (vault-spec §14). This is UX guidance, **not** a security
/// control and not a gate — first-run never blocks on it. The real guidance is the "6+ words"
/// passphrase nudge. Deliberately a lightweight built-in estimator (no zxcvbn dependency).
struct PasswordStrength: Equatable {
    enum Level: Int, Comparable, CaseIterable {
        case veryWeak, weak, fair, good, strong
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .veryWeak: return "Very weak"
            case .weak:     return "Weak"
            case .fair:     return "Fair"
            case .good:     return "Good"
            case .strong:   return "Strong"
            }
        }
    }

    let level: Level
    /// A rough entropy estimate in bits — shown as a hint only, never presented as a guarantee.
    let estimatedBits: Double
    let isPassphraseLike: Bool
    /// One-line nudge toward a stronger choice (always the passphrase guidance for weak inputs).
    let hint: String
}

enum PasswordStrengthEstimator {

    /// Estimate strength with a small heuristic: passphrases are scored by word count (diceware-ish),
    /// other strings by length × character-pool entropy, with penalties for repeats and obvious
    /// sequences. Thresholds are loose, zxcvbn-flavoured buckets.
    static func estimate(_ password: String) -> PasswordStrength {
        if password.isEmpty {
            return PasswordStrength(level: .veryWeak, estimatedBits: 0, isPassphraseLike: false,
                                    hint: "Use a passphrase of 6+ words you can remember.")
        }

        let words = password.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
        let isPassphraseLike = words.count >= 3 && words.allSatisfy { $0.count >= 2 }

        let rawBits: Double
        if isPassphraseLike {
            // ~12.9 bits/word is the EFF diceware figure; be conservative for human-chosen words.
            rawBits = Double(words.count) * 11.0
        } else {
            rawBits = Double(password.count) * log2(Double(max(poolSize(password), 2)))
        }

        let bits = max(0, rawBits - penalties(password))

        let level: PasswordStrength.Level
        switch bits {
        case ..<28:  level = .veryWeak
        case ..<40:  level = .weak
        case ..<60:  level = .fair
        case ..<80:  level = .good
        default:     level = .strong
        }

        let hint: String
        if isPassphraseLike {
            hint = words.count >= 6 ? "Great — a long passphrase is the strongest master password."
                                    : "Add words: aim for 6+ for a strong master password."
        } else {
            hint = "Tip: a passphrase of 6+ words is stronger and easier to remember than symbols."
        }

        return PasswordStrength(level: level, estimatedBits: bits, isPassphraseLike: isPassphraseLike, hint: hint)
    }

    /// Size of the character pool the password draws from (for the entropy estimate).
    private static func poolSize(_ s: String) -> Int {
        var pool = 0
        if s.contains(where: { $0.isLowercase }) { pool += 26 }
        if s.contains(where: { $0.isUppercase }) { pool += 26 }
        if s.contains(where: { $0.isNumber }) { pool += 10 }
        if s.contains(where: { $0 == " " }) { pool += 1 }
        if s.contains(where: { !$0.isLetter && !$0.isNumber && $0 != " " }) { pool += 32 }
        return pool
    }

    /// Entropy to subtract for predictable structure: long runs of one character and short
    /// ascending/descending or keyboard-ish sequences.
    private static func penalties(_ s: String) -> Double {
        let chars = Array(s.lowercased())
        guard chars.count > 1 else { return 0 }
        var penalty = 0.0

        // Repeated runs (aaaa, 1111).
        var run = 1
        for i in 1..<chars.count {
            if chars[i] == chars[i - 1] {
                run += 1
                if run >= 3 { penalty += 4 }
            } else {
                run = 1
            }
        }

        // Ascending/descending sequences of length ≥3 (abc, 321, cba).
        for i in 2..<max(2, chars.count) where i < chars.count {
            if let a = chars[i - 2].asciiValue, let b = chars[i - 1].asciiValue, let c = chars[i].asciiValue {
                if (Int(b) - Int(a) == 1 && Int(c) - Int(b) == 1) ||
                   (Int(a) - Int(b) == 1 && Int(b) - Int(c) == 1) {
                    penalty += 4
                }
            }
        }
        return penalty
    }
}
