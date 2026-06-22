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

    private var isNew: Bool { existing == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(isNew ? "New Login" : "Edit Login").font(.title2).bold()

                labeled("Title") { TextField("e.g. GitHub", text: $title).textFieldStyle(.roundedBorder) }
                labeled("Username") { TextField("you@example.com", text: $username).textFieldStyle(.roundedBorder) }
                labeled("Password") { VaultPasswordField(placeholder: "Password", text: $password) }
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
    }

    private func save() async {
        let trimmedTOTP = totpURI.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = LoginPayload(username: username, password: password, notes: notes,
                                   totp: trimmedTOTP.isEmpty ? nil : trimmedTOTP,
                                   urls: website.isEmpty ? [] : [website])
        await gate.saveItem(id: existing?.id, title: title, payload: payload, hosts: derivedHosts())
        onDone()
    }

    /// Scan a QR image into the TOTP field (first otpauth:// found).
    private func scanTOTPImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var data = (try? Data(contentsOf: url, options: [.uncached])) ?? Data()
        defer { data.resetBytes(in: 0..<data.count) }
        if let first = QRDecoder.decodeQRStrings(imageData: data).lazy.compactMap({ TOTPImportCoordinator.decodeTOTPs(from: $0).first }).first {
            totpURI = first.otpauthURI()
        }
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
