import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import SurfrCore

/// One decision per decoded code. `attachTo` defaults to **nil (create-new)** — never auto-attached;
/// `suggestion` is only an *offer* the user can opt into (confirm-don't-auto, per review).
struct TOTPImportDecision: Identifiable {
    let id = UUID()
    let totp: TOTP
    let suggestion: UUID?
    var attachTo: UUID?
}

/// Drives 2FA import (paste / QR image / GAuth migration). Same plaintext-source hygiene as CSV: the
/// image is read once under a single security-scoped window, its bytes wiped after decode, decoded
/// secrets dropped after store, and the source image deleted only on explicit user action.
@MainActor
final class TOTPImportCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, preview, importing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published var decisions: [TOTPImportDecision] = []
    @Published private(set) var summary: ImportSummary?
    /// nil for pasted URIs; set for an image source (→ offer to delete it after).
    @Published private(set) var fromImage = false

    private var url: URL?
    private var accessing = false

    var isActive: Bool { phase != .idle }

    func pickImage(gate: VaultGate) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a screenshot/photo of a QR code (e.g. Google Authenticator export)."
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        url = picked
        fromImage = true
        accessing = picked.startAccessingSecurityScopedResource()

        var imageData = (try? Data(contentsOf: picked, options: [.uncached])) ?? Data()
        defer { imageData.resetBytes(in: 0..<imageData.count) }   // wipe raw image bytes after decode
        let payloads = QRDecoder.decodeQRStrings(imageData: imageData)
        finishDecode(payloads: payloads, gate: gate)
    }

    func paste(_ text: String, gate: VaultGate) {
        url = nil; fromImage = false
        finishDecode(payloads: [text.trimmingCharacters(in: .whitespacesAndNewlines)], gate: gate)
    }

    private func finishDecode(payloads: [String], gate: VaultGate) {
        let totps = payloads.flatMap { Self.decodeTOTPs(from: $0) }
        guard !totps.isEmpty else {
            phase = .failed("No one-time-code QR found. Use a Google Authenticator export QR or an otpauth:// link.")
            stopAccess(); return
        }
        decisions = totps.map { TOTPImportDecision(totp: $0, suggestion: gate.suggestedMatchForTOTP(issuer: $0.issuer), attachTo: nil) }
        phase = .preview
    }

    func commit(gate: VaultGate) async {
        phase = .importing
        let result = await gate.importTOTP(decisions)
        summary = result
        decisions = []   // drop decoded secrets ASAP
        if result.failed { phase = .failed("Import failed — nothing was changed.") }
        else { phase = .done }
    }

    func deleteSourceImage() -> Bool {
        guard let url else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func cancel() { finish() }
    func finish() { stopAccess(); url = nil; fromImage = false; decisions = []; summary = nil; phase = .idle }
    private func stopAccess() { if accessing, let url { url.stopAccessingSecurityScopedResource() }; accessing = false }
    deinit { if accessing, let url { url.stopAccessingSecurityScopedResource() } }

    static func decodeTOTPs(from payload: String) -> [TOTP] {
        if payload.lowercased().hasPrefix("otpauth-migration://") {
            return ((try? OTPMigration.decode(payload)) ?? []).map(\.totp)
        }
        if let t = TOTP(otpauthURI: payload) { return [t] }
        return []
    }
}

struct TOTPImportSheet: View {
    @ObservedObject var coordinator: TOTPImportCoordinator
    @EnvironmentObject private var gate: VaultGate
    @State private var pasted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch coordinator.phase {
            case .preview:   preview
            case .importing: ProgressView("Importing…").frame(maxWidth: .infinity, alignment: .center)
            case .done:      done
            case .failed(let m): failed(m)
            case .idle:      EmptyView()
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import one-time codes").font(.title3).bold()
            Text("\(coordinator.decisions.count) code\(coordinator.decisions.count == 1 ? "" : "s") found")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($coordinator.decisions) { $d in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.totp.issuer.isEmpty ? d.totp.account : d.totp.issuer).lineLimit(1)
                                if !d.totp.account.isEmpty {
                                    Text(d.totp.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            // Default create-new; attaching to the suggested login is an explicit opt-in.
                            Picker("", selection: $d.attachTo) {
                                Text("Create new").tag(UUID?.none)
                                if let s = d.suggestion, let item = gate.items.first(where: { $0.id == s }) {
                                    Text("Attach to “\(item.title)”").tag(UUID?.some(s))
                                }
                            }
                            .labelsHidden().frame(width: 200)
                            .disabled(d.suggestion == nil)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 260)
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))

            HStack {
                Button("Cancel") { coordinator.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(coordinator.decisions.count)") { Task { await coordinator.commit(gate: gate) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import complete").font(.title3).bold()
            if let s = coordinator.summary { Text("Imported \(s.imported) one-time code\(s.imported == 1 ? "" : "s").").foregroundStyle(.secondary) }
            if coordinator.fromImage {
                Divider()
                Text("Delete the QR image?").font(.headline)
                Text("That screenshot/photo contains all of those 2FA seeds in the clear. Deleting unlinks it, but on SSD/APFS a secure overwrite isn’t guaranteed; also remove any copies (Photos, Downloads, cloud, Trash).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Keep image") { coordinator.finish() }
                    Spacer()
                    Button("Delete image", role: .destructive) { _ = coordinator.deleteSourceImage(); coordinator.finish() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack { Spacer(); Button("Done") { coordinator.finish() }.keyboardShortcut(.defaultAction) }
            }
        }
    }

    private func failed(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import 2FA").font(.title3).bold()
            Text(msg).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            // Offer paste as a fallback when there's no image / QR not found.
            HStack {
                TextField("Paste otpauth:// or otpauth-migration:// link", text: $pasted).textFieldStyle(.roundedBorder)
                Button("Decode") { coordinator.paste(pasted, gate: gate); pasted = "" }.disabled(pasted.isEmpty)
            }
            HStack { Spacer(); Button("Close") { coordinator.finish() } }
        }
    }
}
