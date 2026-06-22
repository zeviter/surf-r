import Foundation
import Security

/// Cryptographically secure randomness. CryptoKit exposes no integer-RNG API — its randomness *is*
/// the system CSPRNG — so we draw raw bytes from `SecRandomCopyBytes` and select indices with
/// **rejection sampling** to avoid modulo bias. Every random choice in the generator (including the
/// shuffle) goes through `index`, so bias can't sneak in via a "convenience" RNG.
enum CSPRNG {
    static func randomUInt64() -> UInt64 {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    /// Uniform, unbiased integer in `0..<upperBound`.
    static func index(_ upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        let n = UInt64(upperBound)
        let limit = UInt64.max - (UInt64.max % n)   // reject the partial top bucket
        while true {
            let r = randomUInt64()
            if r < limit { return Int(r % n) }
        }
    }

    /// Fisher–Yates using the SAME unbiased CSPRNG index — no bias reintroduced at shuffle time.
    static func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            array.swapAt(i, index(i + 1))           // j in 0...i
        }
    }
}

public enum PasswordGenerator {

    // MARK: Random characters

    /// Symbol set deliberately excludes quotes, backslash, and space for paste/parse robustness.
    public static let symbols = "!@#$%^&*()-_=+[]{};:,.?/"
    /// Visually ambiguous characters removed when "exclude ambiguous" is on.
    public static let ambiguous: Set<Character> = ["0", "O", "o", "l", "I", "1", "|"]

    public struct RandomOptions: Equatable, Sendable {
        public var length: Int
        public var upper: Bool
        public var lower: Bool
        public var digits: Bool
        public var symbols: Bool
        public var excludeAmbiguous: Bool

        public init(length: Int = 20, upper: Bool = true, lower: Bool = true,
                    digits: Bool = true, symbols: Bool = true, excludeAmbiguous: Bool = false) {
            self.length = length; self.upper = upper; self.lower = lower
            self.digits = digits; self.symbols = symbols; self.excludeAmbiguous = excludeAmbiguous
        }
    }

    /// Per-selected-class character pools, after the exclude-ambiguous filter. Never returns an empty
    /// class (each base set retains members after filtering).
    static func classes(for o: RandomOptions) -> [[Character]] {
        func f(_ s: String) -> [Character] {
            o.excludeAmbiguous ? s.filter { !ambiguous.contains($0) } : Array(s)
        }
        var out: [[Character]] = []
        if o.upper { out.append(f("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) }
        if o.lower { out.append(f("abcdefghijklmnopqrstuvwxyz")) }
        if o.digits { out.append(f("0123456789")) }
        if o.symbols { out.append(f(symbols)) }
        if out.isEmpty { out.append(f("abcdefghijklmnopqrstuvwxyz")) }   // safety net; UI prevents this
        return out
    }

    public static func poolSize(for o: RandomOptions) -> Int {
        classes(for: o).reduce(0) { $0 + $1.count }
    }

    /// `length × log2(poolSize)`. The "≥1 of each selected class" guarantee makes this a <1-bit
    /// overestimate vs. the exact constrained count — standard generator convention; documented.
    public static func entropyBits(for o: RandomOptions) -> Double {
        let pool = poolSize(for: o)
        guard pool > 1, o.length > 0 else { return 0 }
        return Double(o.length) * log2(Double(pool))
    }

    public static func random(_ o: RandomOptions) -> String {
        let classes = classes(for: o)
        let pool = classes.flatMap { $0 }
        let length = max(o.length, classes.count)   // room to place one of each selected class

        var chars: [Character] = []
        chars.reserveCapacity(length)
        for c in classes { chars.append(c[CSPRNG.index(c.count)]) }   // guarantee ≥1 of each
        while chars.count < length { chars.append(pool[CSPRNG.index(pool.count)]) }
        CSPRNG.shuffle(&chars)                                        // unbiased CSPRNG shuffle
        return String(chars)
    }

    // MARK: Diceware passphrase

    public struct PassphraseOptions: Equatable, Sendable {
        public enum Caps: Equatable, Sendable { case none, title, randomWord }
        public var wordCount: Int
        public var separator: String
        public var caps: Caps
        public init(wordCount: Int = 6, separator: String = "-", caps: Caps = .none) {
            self.wordCount = wordCount; self.separator = separator; self.caps = caps
        }
    }

    public static func passphrase(_ o: PassphraseOptions, words: [String] = EFFWordList.words) -> String {
        guard !words.isEmpty, o.wordCount > 0 else { return "" }
        var chosen = (0..<o.wordCount).map { _ in words[CSPRNG.index(words.count)] }
        switch o.caps {
        case .none: break
        case .title: chosen = chosen.map { $0.capitalized }
        case .randomWord: let i = CSPRNG.index(chosen.count); chosen[i] = chosen[i].capitalized
        }
        return chosen.joined(separator: o.separator)
    }

    /// `wordCount × log2(listSize)` (≈ 12.925 bits/word for the 7776-word EFF list).
    public static func passphraseEntropyBits(wordCount: Int, listSize: Int = EFFWordList.words.count) -> Double {
        guard listSize > 1, wordCount > 0 else { return 0 }
        return Double(wordCount) * log2(Double(listSize))
    }

    // MARK: Strength bands (by entropy bits)

    public enum Strength: String, Sendable { case weak = "Weak", fair = "Fair", strong = "Strong", excellent = "Excellent" }
    public static func strength(bits: Double) -> Strength {
        switch bits {
        case ..<40: return .weak
        case ..<60: return .fair
        case ..<80: return .strong
        default:    return .excellent
        }
    }
}

/// The bundled EFF large wordlist (7776 words, CC-BY 3.0). Loaded once from the package resource;
/// **fails loud** if the bundle is missing or the count isn't exactly 7776.
public enum EFFWordList {
    public static let words: [String] = load()

    private static func load() -> [String] {
        guard let url = Bundle.module.url(forResource: "eff_large_wordlist", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("EFF wordlist resource missing from SurfrCore bundle")
        }
        // Lines are "DDDDD\tword" — take the last whitespace-separated token.
        let lines = text.split(whereSeparator: \.isNewline)
        let words: [String] = lines.compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard let last = tokens.last else { return nil }
            return String(last)
        }
        precondition(words.count == 7776, "EFF wordlist must have exactly 7776 words, got \(words.count)")
        return words
    }
}
