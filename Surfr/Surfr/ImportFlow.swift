import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import SurfrCore

/// Drives the CSV import lifecycle with the **plaintext file as the central concern**: it holds a
/// single security-scoped access window from pick → parse → import → delete, reads the file ONCE into
/// memory (read-only, uncached), wipes the raw bytes after parsing, drops the decrypted candidates as
/// soon as they're stored, and never copies/moves/logs the file. The original CSV is deleted only on
/// explicit user action, inside the access window, before access is released.
@MainActor
final class ImportCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, preview, importing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var parse: ImportParseResult?
    @Published private(set) var summary: ImportSummary?

    private var url: URL?
    private var accessing = false

    var isActive: Bool { phase != .idle }

    /// Pick a CSV and parse it (no encryption yet). Opens read-only; bounds the size; wipes the bytes.
    func pickAndParse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a password export (.csv) to import."
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        url = picked
        accessing = picked.startAccessingSecurityScopedResource()
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: picked.path)[.size] as? Int) ?? 0
            guard size <= CSVImport.maxFileBytes else { throw ImportError.tooLarge(maxMB: CSVImport.maxFileBytes / 1024 / 1024) }

            var data = try Data(contentsOf: picked, options: [.uncached])   // read once, read-only
            defer { data.resetBytes(in: 0..<data.count) }                   // wipe raw bytes after parse
            let result = try CSVImport.parse(data: data)
            parse = result
            phase = result.candidates.isEmpty ? .failed("No logins found in the file.") : .preview
        } catch let e as ImportError {
            phase = .failed(message(for: e))
        } catch {
            phase = .failed("Couldn’t read the file.")
        }
        if case .failed = phase { stopAccess() }   // nothing to keep the window open for
    }

    func commit(gate: VaultGate) async {
        guard let parse else { return }
        phase = .importing
        let result = await gate.importLogins(parse.candidates)
        summary = result
        self.parse = nil   // drop the in-memory decrypted candidates ASAP
        phase = result.failed ? .failed("Import failed — nothing was changed.") : .done
    }

    /// Delete the original CSV (explicit user action), inside the access window, before release.
    func deleteOriginalFile() -> Bool {
        guard let url else { return false }
        do { try FileManager.default.removeItem(at: url); return true } catch { return false }
    }

    func cancel() { finish() }

    /// Release everything on every exit path (success/cancel/error).
    func finish() {
        stopAccess()
        url = nil; parse = nil; summary = nil; phase = .idle
    }

    private func stopAccess() {
        if accessing, let url { url.stopAccessingSecurityScopedResource() }
        accessing = false
    }

    deinit { if accessing, let url { url.stopAccessingSecurityScopedResource() } }

    private func message(for error: ImportError) -> String {
        switch error {
        case .tooLarge(let mb): return "That file is larger than \(mb) MB — that doesn’t look like a password export."
        case .notUTF8: return "Couldn’t read the file as text (expected a UTF-8 CSV)."
        case .empty: return "The file is empty."
        case .noDataRows: return "The file has a header but no rows."
        case .unrecognizedFormat(let supported): return "Unrecognized CSV format. Supported: \(supported.joined(separator: ", "))."
        }
    }
}

/// Preview/confirm → import → delete-prompt sheet. Never displays passwords.
struct VaultImportSheet: View {
    @ObservedObject var coordinator: ImportCoordinator
    @EnvironmentObject private var gate: VaultGate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch coordinator.phase {
            case .preview:   preview
            case .importing: ProgressView("Importing…").frame(maxWidth: .infinity, alignment: .center)
            case .done:      done
            case .failed(let msg): failed(msg)
            case .idle:      EmptyView()
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    @ViewBuilder private var preview: some View {
        if let parse = coordinator.parse {
            Text("Import from \(parse.format)").font(.title3).bold()
            Text("\(parse.candidates.count) login\(parse.candidates.count == 1 ? "" : "s") found"
                 + (parse.skipped.isEmpty ? "" : " · \(parse.skipped.count) row\(parse.skipped.count == 1 ? "" : "s") skipped"))
                .foregroundStyle(.secondary)
            if parse.totpMayBeMissing {
                Label("LastPass may omit one-time-code (TOTP) seeds. Re-add 2FA on those sites after the TOTP update.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            // Title + username only — never passwords.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parse.candidates.prefix(50).enumerated()), id: \.offset) { _, c in
                        HStack {
                            Text(c.title).lineLimit(1)
                            Spacer()
                            Text(c.payload.username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if parse.candidates.count > 50 {
                        Text("+ \(parse.candidates.count - 50) more…").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))

            HStack {
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(parse.candidates.count)") { Task { await coordinator.commit(gate: gate) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var done: some View {
        Text("Import complete").font(.title3).bold()
        if let s = coordinator.summary {
            Text("Imported \(s.imported)"
                 + (s.skippedDuplicates > 0 ? " · \(s.skippedDuplicates) duplicate\(s.skippedDuplicates == 1 ? "" : "s") skipped" : ""))
                .foregroundStyle(.secondary)
        }
        Divider()
        Text("Delete the CSV file?").font(.headline)
        Text("It still contains all your passwords in the clear — it’s the exposure, not your vault. Deleting unlinks the file, but on SSD/APFS a secure overwrite isn’t guaranteed; also remove any copies (Downloads, cloud, Trash).")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Keep file") { coordinator.finish() }
            Spacer()
            Button("Delete CSV file", role: .destructive) { _ = coordinator.deleteOriginalFile(); coordinator.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func failed(_ msg: String) -> some View {
        Text("Import").font(.title3).bold()
        Text(msg).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        HStack { Spacer(); Button("OK") { coordinator.finish() }.keyboardShortcut(.defaultAction) }
    }
}
