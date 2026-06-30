import SwiftUI
import AppKit
import Combine
import SurfrCore

/// One shared field-row metric so every typed detail/edit surface breathes consistently (TV-2a Fix 2).
private let vaultFieldVPadding: CGFloat = 7
private extension View {
    /// Consistent top + bottom breathing room for a vault field row (label + value/control).
    func vaultFieldRow() -> some View { padding(.vertical, vaultFieldVPadding) }
}

// MARK: - Shared "X copied" confirmation (concealed clipboard + 30s auto-clear via VaultClipboard)

@MainActor
final class CopyToaster: ObservableObject {
    @Published var message: String?
    private var clearTask: Task<Void, Never>?

    /// Copy a value to the **concealed** clipboard (auto-clears in 30s) and flash a confirmation.
    func copy(_ value: String, label: String) {
        VaultClipboard.copyConcealed(value)
        message = "\(label) copied"
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

private struct CopyConfirmation: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.4)))
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
    }
}
private extension View {
    func copyConfirmation(_ message: Binding<String?>) -> some View { modifier(CopyConfirmation(message: message)) }
}

/// A detail header used by the typed surfaces: a generic glyph + title (no favicon — typed items have
/// no first-party host).
private struct TypedDetailHeader: View {
    let systemImage: String
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title.isEmpty ? "Untitled" : title).font(.title2).bold()
        }
    }
}

private func detailFieldLabel(_ text: String) -> some View {
    Text(text.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
}

// MARK: - Secure Note — detail (WF-15)

/// Secure Note detail: title + free-text body (the preserved raw body for re-classified long-tail
/// items). The vault is already unlocked, so the body shows in plaintext; copy-whole-note uses the
/// concealed clipboard. Body is dropped from memory on close. (Title is cleartext metadata; the body
/// stays in the encrypted payload — never searchable.)
struct SecureNoteDetailView: View {
    let item: StoredItem
    @EnvironmentObject private var gate: VaultGate
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var noteBody = ""
    @State private var loadFailed = false
    @State private var confirmingDelete = false
    @StateObject private var toaster = CopyToaster()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                TypedDetailHeader(systemImage: "note.text", title: item.title)
                    .padding(.bottom, 6)

                if loadFailed {
                    Label("Couldn’t decrypt this item.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            detailFieldLabel("Note")
                            Spacer()
                            Button { toaster.copy(noteBody, label: "Note") } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain).help("Copy the whole note").disabled(noteBody.isEmpty)
                        }
                        Text(noteBody.isEmpty ? "—" : noteBody)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                    }
                    .vaultFieldRow()
                }

                HStack {
                    Button("Edit", action: onEdit)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                .padding(.top, 8)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .copyConfirmation($toaster.message)
        .task {
            if let payload = gate.decryptPayload(item) { noteBody = payload.notes } else { loadFailed = true }
        }
        .onDisappear { noteBody = "" }   // drop plaintext on close
        .confirmationDialog("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Secure Note — edit (WF-15)

/// Secure Note editor — a plain notepad: title (cleartext metadata) + multi-line body (encrypted). No
/// structured parsing; the raw body is the source of truth. Stored as a `secureNote` item (body in the
/// payload's notes field — the same shape re-classified notes use).
struct SecureNoteEditView: View {
    let existing: StoredItem?
    @EnvironmentObject private var gate: VaultGate
    let onDone: () -> Void

    @State private var title = ""
    @State private var noteBody = ""
    @State private var loaded = false

    private var isNew: Bool { existing == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "New Secure Note" : "Edit Secure Note").font(.title2).bold().padding(.bottom, 6)

                labeled("Title") { TextField("e.g. Passport (UK)", text: $title).textFieldStyle(.roundedBorder) }
                labeled("Note") {
                    TextEditor(text: $noteBody).frame(minHeight: 200)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
                }

                HStack {
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isNew ? "Add" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            guard !loaded else { return }
            loaded = true
            if let existing { title = existing.title; noteBody = gate.decryptPayload(existing)?.notes ?? "" }
        }
        .onDisappear { noteBody = "" }
    }

    private func save() async {
        guard let data = try? LoginPayload(notes: noteBody).encoded() else { return }
        await gate.saveTypedItem(id: existing?.id, type: VaultItemType.secureNote,
                                 title: title.trimmingCharacters(in: .whitespaces),
                                 payloadData: data, hosts: existing?.hosts ?? [])
        onDone()
    }

    @ViewBuilder private func labeled<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { detailFieldLabel(label); content() }
            .vaultFieldRow()
    }
}

// MARK: - Address — detail (WF-16)

/// Address detail: discrete fields, **empty fields omitted**, per-field copy (concealed clipboard).
/// `county` and `stateProvince` are independent — whichever is set renders. All values are
/// encrypted-payload; only the label (title) is cleartext/searchable.
struct AddressDetailView: View {
    let item: StoredItem
    @EnvironmentObject private var gate: VaultGate
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var address: AddressPayload?
    @State private var loadFailed = false
    @State private var confirmingDelete = false
    @StateObject private var toaster = CopyToaster()

    private var fullName: String {
        guard let a = address else { return "" }
        return [a.firstName, a.lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                TypedDetailHeader(systemImage: "mappin.and.ellipse", title: item.title)
                    .padding(.bottom, 6)

                if loadFailed {
                    Label("Couldn’t decrypt this item.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let a = address {
                    field("Name", fullName)
                    field("Company", a.company)
                    field("Address line 1", a.line1)
                    field("Address line 2", a.line2)
                    field("City / District", a.city)
                    field("County", a.county ?? "")
                    field("State / Province", a.stateProvince ?? "")
                    field("Postal code", a.postalCode)
                    field("Country", a.country,
                          check: CountryList.isRecognised(a.country) ? .ok : .suspect("not a recognised country"))
                    field("Phone", a.phone)
                    field("Email", a.email)
                    field("Notes", a.notes)
                }

                HStack {
                    Button("Edit", action: onEdit)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                .padding(.top, 8)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .copyConfirmation($toaster.message)
        .task {
            if let a = gate.decryptAddress(item) { address = a } else { loadFailed = true }
        }
        .onDisappear { address = nil }
        .confirmationDialog("Delete this address?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// Render a labelled field only when it has a value (empty fields omitted in detail). A `.suspect`
    /// check flags it amber + a hint (soft).
    @ViewBuilder private func field(_ label: String, _ value: String, check: FieldCheck = .ok) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                detailFieldLabel(label)
                HStack {
                    Text(value).textSelection(.enabled)
                    Spacer()
                    Button { toaster.copy(value, label: label) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy \(label.lowercased())")
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                .suspectBorder(check.isSuspect)
                ValidationHint(check: check)
            }
            .vaultFieldRow()
        }
    }
}

// MARK: - Address — edit (WF-16)

/// Address editor — a labelled form with all discrete fields (county AND state both present, either may
/// be blank). Values stored **as entered** (no auto-formatting). The raw imported body is preserved
/// (round-tripped) so nothing that didn't map is lost.
struct AddressEditView: View {
    let existing: StoredItem?
    @EnvironmentObject private var gate: VaultGate
    let onDone: () -> Void

    @State private var label = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var company = ""
    @State private var line1 = ""
    @State private var line2 = ""
    @State private var city = ""
    @State private var county = ""
    @State private var stateProvince = ""
    @State private var postalCode = ""
    @State private var country = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var notes = ""
    @State private var rawBody = ""
    @State private var phoneCountry: String?
    @State private var loaded = false
    @State private var savedWarning = false

    private var isNew: Bool { existing == nil }
    private var countryRecognised: Bool { CountryList.isRecognised(country) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Address" : "Edit Address").font(.title2).bold().padding(.bottom, 6)

                field("Label", $label, placeholder: "e.g. Home")
                HStack(spacing: 10) { field("First name", $firstName); field("Last name", $lastName) }
                field("Company", $company)
                field("Address line 1", $line1)
                field("Address line 2", $line2)
                field("City / District", $city)
                HStack(spacing: 10) { field("County", $county); field("State / Province", $stateProvince) }
                HStack(alignment: .top, spacing: 10) { field("Postal code", $postalCode); countryPicker }
                field("Phone", $phone)
                field("Email", $email)
                notesField

                if savedWarning { SavedAnywayBanner(onDone: onDone).padding(.vertical, 6) }

                HStack {
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Spacer()
                    // NEVER disabled — save always succeeds (the load-bearing TV-2-VAL rule).
                    Button(isNew ? "Add" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            guard !loaded else { return }
            loaded = true
            label = existing?.title ?? ""
            guard let a = existing.flatMap({ gate.decryptAddress($0) }) else { return }
            firstName = a.firstName; lastName = a.lastName; company = a.company
            line1 = a.line1; line2 = a.line2; city = a.city
            county = a.county ?? ""; stateProvince = a.stateProvince ?? ""
            postalCode = a.postalCode; country = a.country; phone = a.phone; email = a.email
            notes = a.notes; phoneCountry = a.phoneCountry; rawBody = a.rawBody
            if label.isEmpty { label = a.label }
        }
    }

    private func save() async {
        func n(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        let addr = AddressPayload(
            label: label, firstName: firstName, lastName: lastName, company: company,
            line1: line1, line2: line2, city: city, county: n(county), stateProvince: n(stateProvince),
            postalCode: postalCode, country: country, phone: phone, phoneCountry: phoneCountry,
            email: email, notes: notes, rawBody: rawBody
        )
        guard let data = try? addr.encoded() else { return }
        await gate.saveTypedItem(id: existing?.id, type: VaultItemType.address,
                                 title: label.trimmingCharacters(in: .whitespaces),
                                 payloadData: data, hosts: existing?.hosts ?? [])
        if countryRecognised { onDone() } else { savedWarning = true }   // saved either way
    }

    /// Country is a PICKER (ISO list), not free text. An imported value that doesn't match a known
    /// country is shown flagged but still selectable/keepable (soft).
    private var countryPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            detailFieldLabel("Country")
            Picker(selection: $country) {
                Text("—").tag("")
                if !country.isEmpty && !countryRecognised { Text("\(country) — not recognised").tag(country) }
                ForEach(CountryList.names, id: \.self) { Text($0).tag($0) }
            } label: { EmptyView() }
            .labelsHidden().pickerStyle(.menu)
            ValidationHint(check: countryRecognised ? .ok : .suspect("not a recognised country — pick one"))
        }
        .vaultFieldRow()
    }

    @ViewBuilder private func field(_ title: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            detailFieldLabel(title)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .vaultFieldRow()
    }

    /// Multi-line free-form notes (the terminal Notes tail) — a small text editor, not a single-line field.
    private var notesField: some View {
        VStack(alignment: .leading, spacing: 5) {
            detailFieldLabel("Notes")
            TextEditor(text: $notes).frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
        }
        .vaultFieldRow()
    }
}

// MARK: - Generic interim placeholder (defensive — for a known type without a detail view yet)

/// Honest interim state for a **known item type that has no detail view yet**. As of TV-2c every shipped
/// type (login / note / address / payment / bank account) has a real view, so this is **purely defensive**
/// — only a future/reserved type (e.g. the reserved `passkey` v2 type) would land here until its view
/// ships. No shipped type reaches it. Not a decryption-failure message: the data is intact, there's just
/// no typed view.
struct TypedInterimView: View {
    let item: StoredItem
    let onDelete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TypedDetailHeader(systemImage: "doc.text", title: item.title)
                Label("Details — full view coming in the next update.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Delete", role: .destructive) { confirmingDelete = true } }
                    .padding(.top, 8)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Delete this item?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Add-new type picker (WF-13)

/// The `+` picker: Password · Secure Note · Address · Payment (Payment disabled until TV-2b).
/// Keyboard-first — default focus first option, ↑↓ move, ↵ selects, ESC cancels.
struct TypePickerView: View {
    enum Choice { case login, note, address, payment, bankAccount }
    let onSelect: (Choice) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var selected = 0

    private struct Option { let glyph: String; let label: String; let choice: Choice?; let note: String? }
    private let options: [Option] = [
        .init(glyph: "key.fill",        label: "Password",       choice: .login,   note: nil),
        .init(glyph: "note.text",       label: "Secure Note",    choice: .note,    note: nil),
        .init(glyph: "mappin.and.ellipse", label: "Address",     choice: .address, note: nil),
        .init(glyph: "creditcard",      label: "Payment Method", choice: .payment, note: nil),
        .init(glyph: "building.columns", label: "Bank Account",  choice: .bankAccount, note: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New item…").font(.caption).bold().foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                row(option, selected: index == selected)
                    .contentShape(Rectangle())
                    .onTapGesture { choose(index) }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25)))
        .shadow(radius: 20, y: 8)
        .focusable()
        .focused($focused)
        .onAppear { focused = true; selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, options.count - 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.return) { choose(selected); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func choose(_ index: Int) {
        guard let choice = options[index].choice else { return }   // disabled (payment)
        onSelect(choice)
    }

    private func row(_ option: Option, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: option.glyph).frame(width: 20).foregroundStyle(option.choice == nil ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label).foregroundStyle(option.choice == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                if let note = option.note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected && option.choice != nil ? Color.accentColor.opacity(0.18) : .clear))
        .padding(.horizontal, 6)
    }
}
