import Foundation
import SurfrCore

/// One parsed, mapped login ready to encrypt-and-store. `title`/`hosts` are the cleartext metadata;
/// `payload` is the secret blob.
struct ImportCandidate: Equatable {
    var title: String
    var hosts: [SurfrCore.Host]
    var payload: LoginPayload
}

/// Outcome of parsing a CSV (before any encryption/storage).
struct ImportParseResult: Equatable {
    var format: String
    var candidates: [ImportCandidate]
    var skipped: [SkippedRow]
    /// LastPass often omits TOTP seeds even for 2FA sites → surface a blanket note (Slice 7 re-add).
    var totpMayBeMissing: Bool

    struct SkippedRow: Equatable { var row: Int; var reason: String }
}

enum ImportError: Error, Equatable {
    case tooLarge(maxMB: Int)
    case notUTF8
    case empty                       // no header
    case noDataRows                  // header only / all-empty
    case unrecognizedFormat(supported: [String])
}

// MARK: - Format profiles + detection

enum CSVImport {
    /// Hard cap so a mis-picked huge file can't blow up memory (a real password CSV is tiny).
    static let maxFileBytes = 25 * 1024 * 1024

    private enum Col { case title, username, password, url, notes, totp }

    private struct Profile {
        let name: String
        let signature: Set<String>      // normalised headers that must ALL be present to match
        let map: [Col: String]          // field → header name (normalised)
    }

    private static let profiles: [Profile] = [
        Profile(name: "LastPass",
                signature: ["url", "username", "password", "name", "extra", "grouping"],
                map: [.title: "name", .username: "username", .password: "password",
                      .url: "url", .notes: "extra", .totp: "totp"]),
        Profile(name: "Bitwarden",
                signature: ["name", "login_uri", "login_username", "login_password"],
                map: [.title: "name", .username: "login_username", .password: "login_password",
                      .url: "login_uri", .notes: "notes", .totp: "login_totp"]),
        Profile(name: "Safari",
                signature: ["title", "url", "username", "password"],
                map: [.title: "title", .username: "username", .password: "password",
                      .url: "url", .notes: "notes", .totp: "otpauth"]),
        Profile(name: "Chrome",
                signature: ["name", "url", "username", "password"],
                map: [.title: "name", .username: "username", .password: "password",
                      .url: "url", .notes: "note", .totp: ""]),
    ]

    static var supportedFormats: [String] { profiles.map(\.name) }

    /// Parse + map a CSV's raw bytes into candidates. Never touches disk.
    static func parse(data: Data) throws -> ImportParseResult {
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge(maxMB: maxFileBytes / 1024 / 1024) }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }

        let rows = CSV.parse(text)
        guard let header = rows.first else { throw ImportError.empty }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let headerSet = Set(normalized)

        guard let profile = detect(headerSet) else {
            throw ImportError.unrecognizedFormat(supported: supportedFormats)
        }
        let dataRows = Array(rows.dropFirst())
        guard !dataRows.isEmpty else { throw ImportError.noDataRows }

        // Column name → index.
        var index: [String: Int] = [:]
        for (i, h) in normalized.enumerated() where index[h] == nil { index[h] = i }

        func value(_ col: Col, _ fields: [String]) -> String {
            guard let key = profile.map[col], !key.isEmpty, let i = index[key], i < fields.count else { return "" }
            return fields[i]
        }

        var candidates: [ImportCandidate] = []
        var skipped: [ImportParseResult.SkippedRow] = []

        for (offset, fields) in dataRows.enumerated() {
            let rowNumber = offset + 2   // 1-based, +1 for the header
            // Truly empty row → skip silently-ish (reported).
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                skipped.append(.init(row: rowNumber, reason: "empty row")); continue
            }
            let title = value(.title, fields)
            let username = value(.username, fields)
            let password = value(.password, fields)
            let url = value(.url, fields)
            if title.isEmpty && username.isEmpty && password.isEmpty && url.isEmpty {
                skipped.append(.init(row: rowNumber, reason: "no usable fields")); continue
            }
            let totpRaw = value(.totp, fields).trimmingCharacters(in: .whitespaces)
            let payload = LoginPayload(
                username: username,
                password: password,
                notes: value(.notes, fields),
                totp: totpRaw.isEmpty ? nil : totpRaw,
                urls: url.isEmpty ? [] : [url]
            )
            let host = Self.host(from: url)
            let resolvedTitle = title.isEmpty ? (host ?? url) : title
            let hosts = host.map { [SurfrCore.Host(host: $0, isPrimary: true)] } ?? []
            candidates.append(ImportCandidate(title: resolvedTitle, hosts: hosts, payload: payload))
        }

        return ImportParseResult(format: profile.name,
                                 candidates: candidates,
                                 skipped: skipped,
                                 totpMayBeMissing: profile.name == "LastPass")
    }

    /// Most-specific match wins (largest matched signature); ties broken by profile order above.
    private static func detect(_ headers: Set<String>) -> Profile? {
        profiles
            .filter { $0.signature.isSubset(of: headers) }
            .max { $0.signature.count < $1.signature.count }
    }

    /// Store the **registrable domain** for an imported credential's URL — robustly, even when the
    /// LastPass `url` is a full sign-in URL with query/fragment that `URL(string:)` can't parse. Keeps
    /// `item_hosts` clean (`amazon.co.uk`, never `www.amazon.co.uk` or a full URL) so matching is exact.
    static func host(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let domain = TrustStore.registrableDomain(forHostOrURL: trimmed)
        return domain.isEmpty ? nil : domain
    }
}
