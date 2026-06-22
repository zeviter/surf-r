import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SurfrCore

/// Add or edit a login (WF-6). The generator popover lands in Slice 6 — for now the password uses the
/// reusable reveal field. Saving encrypts the payload and upserts via the gate.
struct VaultEditView: View {
    /// nil = new item.
    let existing: StoredItem?
    @EnvironmentObject private var gate: VaultGate
    let onDone: () -> Void

    @State private var title = ""
    @State private var username = ""
    @State private var password = ""
    @State private var website = ""
    @State private var notes = ""
    @State private var totpURI = ""
    @State private var loaded = false
    @State private var showGenerator = false
    // In-Edit QR scan: hold the source image (access stays open) until the delete decision.
    @State private var scannedImageURL: URL?
    @State private var scanAccessing = false
    @State private var showDeleteScanPrompt = false
    @State private var scanMessage: String?

    private var isNew: Bool { existing == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(isNew ? "New Login" : "Edit Login").font(.title2).bold()

                labeled("Title") { TextField("e.g. GitHub", text: $title).textFieldStyle(.roundedBorder) }
                labeled("Username") { TextField("you@example.com", text: $username).textFieldStyle(.roundedBorder) }
                labeled("Password") {
                    HStack {
                        VaultPasswordField(placeholder: "Password", text: $password)
                        Button { showGenerator = true } label: { Image(systemName: "wand.and.stars") }
                            .help("Generate a password")
                            .popover(isPresented: $showGenerator, arrowEdge: .bottom) {
                                GeneratorView { password = $0; showGenerator = false }
                            }
                    }
                }
                labeled("Website") { TextField("https://example.com", text: $website).textFieldStyle(.roundedBorder) }
                labeled("Notes") {
                    TextEditor(text: $notes).frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
                }
                labeled("One-time code (TOTP)") {
                    HStack {
                        TextField("otpauth://… or leave blank", text: $totpURI).textFieldStyle(.roundedBorder)
                        Button("Scan image…") { scanTOTPImage() }
                    }
                    if let m = scanMessage { Text(m).font(.caption).foregroundStyle(.orange) }
                    if !totpURI.isEmpty, TOTP(otpauthURI: totpURI) == nil {
                        Text("Not a valid otpauth:// link.").font(.caption).foregroundStyle(.red)
                    }
                }

                HStack {
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isNew ? "Add" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(title.isEmpty && username.isEmpty && website.isEmpty)
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            guard !loaded, let existing, let payload = gate.decryptPayload(existing) else { loaded = true; return }
            title = existing.title
            username = payload.username
            password = payload.password
            website = payload.urls.first ?? existing.hosts.first?.host ?? ""
            notes = payload.notes
            totpURI = payload.totp ?? ""
            loaded = true
        }
        .confirmationDialog("Delete the QR image?", isPresented: $showDeleteScanPrompt, titleVisibility: .visible) {
            Button("Delete image", role: .destructive) { resolveScannedImage(delete: true) }
            Button("Keep image", role: .cancel) { resolveScannedImage(delete: false) }
        } message: {
            Text("That image contains this 2FA seed in the clear. Deleting unlinks it, but on SSD/APFS a secure overwrite isn’t guaranteed; also remove any copies (Photos, Downloads, cloud, Trash).")
        }
    }

    private func save() async {
        let trimmedTOTP = totpURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = LoginPayload(username: username, password: password, notes: notes,
                                   totp: trimmedTOTP.isEmpty ? nil : trimmedTOTP,
                                   urls: website.isEmpty ? [] : [website])
        await gate.saveItem(id: existing?.id, title: title, payload: payload, hosts: derivedHosts())
        onDone()
    }

    /// Scan a QR image into the TOTP field (first otpauth:// found). On success the source image —
    /// a plaintext 2FA seed on disk — is held open so we can offer to delete it (same hygiene as the
    /// bulk "Import 2FA…" path); on failure we surface a message instead of doing nothing.
    private func scanTOTPImage() {
        scanMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        var data = (try? Data(contentsOf: url, options: [.uncached])) ?? Data()
        let found = QRDecoder.decodeQRStrings(imageData: data)
            .lazy.compactMap { TOTPImportCoordinator.decodeTOTPs(from: $0).first }.first
        data.resetBytes(in: 0..<data.count)   // wipe raw image bytes after decode

        if let found {
            totpURI = found.otpauthURI()
            scannedImageURL = url              // keep access open for the delete decision
            scanAccessing = accessing
            showDeleteScanPrompt = true
        } else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            scanMessage = "No one-time-code QR found in that image."
        }
    }

    /// Resolve the post-scan delete prompt: delete happens inside the access window, before release.
    private func resolveScannedImage(delete: Bool) {
        if let url = scannedImageURL {
            if delete { try? FileManager.default.removeItem(at: url) }
            if scanAccessing { url.stopAccessingSecurityScopedResource() }
        }
        scannedImageURL = nil; scanAccessing = false
    }

    /// Derive the registrable host from the website field for `item_hosts` (drives favicon + fill).
    private func derivedHosts() -> [SurfrCore.Host] {
        let trimmed = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: withScheme)?.host, !host.isEmpty else { return [] }
        return [SurfrCore.Host(host: host.lowercased(), isPrimary: true)]
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            content()
        }
    }
}
