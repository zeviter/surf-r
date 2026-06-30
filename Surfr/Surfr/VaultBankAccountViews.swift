import SwiftUI
import AppKit
import Combine
import SurfrCore

// A classical-bank glyph, deliberately distinct from the payment card glyph (TV-2c).
private let bankGlyph = "building.columns"

// The account-type picker's fixed list (WF-13/§11 pre-shape). An imported value outside the list is
// preserved as its own selectable tag (the "freeform fallback") so an odd import is never trapped.
private let bankAccountTypes = ["Current", "Savings", "Checking", "Business", "Joint", "Premier"]

// MARK: - Bank Account detail model — reuses the Slice-5 reveal/copy + biometric-gate machinery for the
// three sensitive fields (account number + IBAN + PIN). No new reveal logic: the auth gate, master
// fallback, and concealed clipboard are the gate's; this only orchestrates them for three secrets — the
// exact PaymentDetailModel shape, with three secrets instead of two.

@MainActor
final class BankAccountDetailModel: ObservableObject {
    @Published private(set) var bankName = ""
    @Published private(set) var accountType = ""
    @Published private(set) var sortCode = ""        // shown plainly (not secret); display XX-XX-XX
    @Published private(set) var swift = ""           // BIC — public, shown plainly
    @Published private(set) var branchAddress = ""
    @Published private(set) var branchPhone = ""
    @Published private(set) var notes = ""
    @Published private(set) var accountLast4 = ""
    @Published private(set) var numberRevealed: String?   // account number; nil = masked
    @Published private(set) var ibanRevealed: String?
    @Published private(set) var pinRevealed: String?
    // Soft validation (TV-2-VAL): computed once at load (without revealing) so detail can flag junk amber.
    @Published private(set) var accountCheck: FieldCheck = .ok
    @Published private(set) var ibanCheck: FieldCheck = .ok
    @Published private(set) var pinCheck: FieldCheck = .ok
    @Published private(set) var sortCodeCheck: FieldCheck = .ok
    @Published private(set) var swiftCheck: FieldCheck = .ok
    @Published private(set) var loadFailed = false
    @Published var awaitingMaster = false
    @Published var masterError = false
    @Published var copyConfirmation: String?

    enum Field { case account, iban, pin }
    private enum Action { case reveal(Field), copy(Field) }
    private var pending: Action?

    private var accountNumber = WipeableSecret("")
    private var iban = WipeableSecret("")
    private var pin = WipeableSecret("")
    private var copyClearTask: Task<Void, Never>?

    func load(_ item: StoredItem, gate: VaultGate) {
        guard let b = gate.decryptBankAccount(item) else { loadFailed = true; return }
        bankName = b.bankName
        accountType = b.accountType
        sortCode = BankValidation.formatSortCode(b.sortCode)
        swift = b.swift
        branchAddress = b.branchAddress
        branchPhone = b.branchPhone
        notes = b.notes
        accountNumber = WipeableSecret(b.accountNumber)
        iban = WipeableSecret(b.iban)
        pin = WipeableSecret(b.pin)
        accountCheck = BankValidation.accountNumber(b.accountNumber)   // flag junk without revealing
        ibanCheck = BankValidation.iban(b.iban)
        pinCheck = BankValidation.pin(b.pin)
        sortCodeCheck = BankValidation.sortCode(b.sortCode)
        swiftCheck = BankValidation.swift(b.swift)
        accountLast4 = item.accountLast4 ?? BankValidation.accountLast4(b.accountNumber)   // cleartext hint preferred
    }

    /// The header name: the decrypted bank name, falling back to the item title (cleartext) if absent.
    func headerName(itemTitle: String) -> String { bankName.isEmpty ? itemTitle : bankName }

    var hasAccount: Bool { !accountNumber.isEmpty }
    var hasIBAN: Bool { !iban.isEmpty }
    var hasPIN: Bool { !pin.isEmpty }
    var maskedAccount: String {
        if let r = numberRevealed { return r }
        return accountLast4.isEmpty ? "••••" : "•••• \(accountLast4)"
    }
    var maskedIBAN: String { ibanRevealed ?? "••••••••" }
    var maskedPIN: String { pinRevealed ?? "••••" }

    func conceal(_ f: Field) {
        switch f {
        case .account: numberRevealed = nil
        case .iban:    ibanRevealed = nil
        case .pin:     pinRevealed = nil
        }
    }

    func requestReveal(_ f: Field, gate: VaultGate) async { await authThenPerform(.reveal(f), gate: gate) }
    func requestCopy(_ f: Field, gate: VaultGate) async { await authThenPerform(.copy(f), gate: gate) }

    private func authThenPerform(_ action: Action, gate: VaultGate) async {
        if !gate.requireAuthToReveal { perform(action); return }
        if gate.biometricState == .enabled, await gate.biometricAuthenticateForReveal() { perform(action); return }
        pending = action; masterError = false; awaitingMaster = true   // master fallback (never a dead end)
    }

    func submitMaster(_ pw: String, gate: VaultGate) async {
        guard await gate.verifyMaster(pw) else { masterError = true; return }
        awaitingMaster = false; masterError = false
        if let p = pending { perform(p) }
        pending = nil
    }
    func cancelMaster() { awaitingMaster = false; masterError = false; pending = nil }

    private func secret(_ f: Field) -> WipeableSecret {
        switch f { case .account: return accountNumber; case .iban: return iban; case .pin: return pin }
    }
    private func label(_ f: Field) -> String {
        switch f { case .account: return "Account number"; case .iban: return "IBAN"; case .pin: return "PIN" }
    }

    private func perform(_ action: Action) {
        switch action {
        case .reveal(let f):
            let v = secret(f).reveal()
            switch f { case .account: numberRevealed = v; case .iban: ibanRevealed = v; case .pin: pinRevealed = v }
        case .copy(let f):
            VaultClipboard.copyConcealed(secret(f).reveal()); noteCopied(label(f))
        }
    }

    /// Non-sensitive per-field copy (concealed clipboard, but no auth gate).
    func copyField(_ value: String, label: String) { VaultClipboard.copyConcealed(value); noteCopied(label) }

    func noteCopied(_ label: String) {
        copyConfirmation = "\(label) copied"
        copyClearTask?.cancel()
        copyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self?.copyConfirmation = nil }
        }
    }

    /// Zero all three secrets + clear decrypted fields (on disappear) — the password-field lifetime discipline.
    func wipe() {
        accountNumber.wipe(); iban.wipe(); pin.wipe()
        numberRevealed = nil; ibanRevealed = nil; pinRevealed = nil
        bankName = ""; accountType = ""; sortCode = ""; swift = ""
        branchAddress = ""; branchPhone = ""; notes = ""
        awaitingMaster = false; masterError = false; pending = nil
    }

    var secretsWipedForTest: Bool { accountNumber.isWiped && iban.isWiped && pin.isWiped }
}

// MARK: - Bank Account detail (WF-17-style, TV-2c)

struct BankAccountDetailView: View {
    let item: StoredItem
    @EnvironmentObject private var gate: VaultGate
    let onEdit: () -> Void
    let onDelete: () -> Void

    @StateObject private var model = BankAccountDetailModel()
    @State private var confirmingDelete = false
    @State private var fallbackMaster = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Image(systemName: bankGlyph).font(.system(size: 30)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.headerName(itemTitle: item.title.isEmpty ? "Bank account" : item.title))
                            .font(.title2).bold()
                        if !model.accountLast4.isEmpty {
                            Text("•••• \(model.accountLast4)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 6)

                if model.loadFailed {
                    Label("Couldn’t decrypt this item.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else {
                    plainField("Bank name", model.bankName)
                    plainField("Account type", model.accountType)
                    plainField("Sort code", model.sortCode, check: model.sortCodeCheck)
                    if model.hasAccount { secretField("Account number", value: model.maskedAccount, field: .account,
                                                      revealed: model.numberRevealed != nil, check: model.accountCheck) }
                    if model.hasIBAN { secretField("IBAN", value: model.maskedIBAN, field: .iban,
                                                   revealed: model.ibanRevealed != nil, check: model.ibanCheck) }
                    if model.hasPIN { secretField("PIN", value: model.maskedPIN, field: .pin,
                                                  revealed: model.pinRevealed != nil, check: model.pinCheck) }
                    if model.awaitingMaster { masterFallback }
                    plainField("SWIFT / BIC", model.swift, check: model.swiftCheck)
                    plainField("Branch address", model.branchAddress)
                    plainField("Branch phone", model.branchPhone)
                    plainField("Notes", model.notes)
                }

                HStack {
                    Button("Edit", action: onEdit)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                .padding(.top, 10)
            }
            .padding(24).frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { copyToast }
        .animation(.easeInOut(duration: 0.2), value: model.copyConfirmation)
        .task { model.load(item, gate: gate) }
        .onDisappear { model.wipe() }
        .confirmationDialog("Delete this bank account?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// A masked, biometric-gated sensitive field (account number / IBAN / PIN) — reveal + copy both gated.
    /// A `.suspect` check flags it amber + a hint (soft; never blocks).
    private func secretField(_ label: String, value: String, field: BankAccountDetailModel.Field,
                             revealed: Bool, check: FieldCheck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    if revealed { model.conceal(field) }
                    else { Task { await model.requestReveal(field, gate: gate) } }
                } label: { Image(systemName: revealed ? "eye.slash.fill" : "eye.fill") }
                    .buttonStyle(.plain).help(revealed ? "Hide" : "Reveal")
                Button { Task { await model.requestCopy(field, gate: gate) } } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy \(label.lowercased())")
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
            .suspectBorder(check.isSuspect)
            ValidationHint(check: check)
        }
        .padding(.vertical, 7)
    }

    /// A non-sensitive field, shown plainly with a concealed-clipboard copy; omitted when empty.
    @ViewBuilder private func plainField(_ label: String, _ value: String, check: FieldCheck = .ok) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
                HStack {
                    Text(value).textSelection(.enabled)
                    Spacer()
                    Button { model.copyField(value, label: label) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy \(label.lowercased())")
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                .suspectBorder(check.isSuspect)
                ValidationHint(check: check)
            }
            .padding(.vertical, 7)
        }
    }

    /// Master-password fallback for reveal/copy (6a) — shown when biometric is cancelled/unavailable.
    private var masterFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter your master password to reveal").font(.caption).foregroundStyle(.secondary)
            HStack {
                VaultPasswordField(placeholder: "Master password", text: $fallbackMaster, autoFocus: true,
                                   onSubmit: { submitFallback() })
                Button("Reveal") { submitFallback() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { fallbackMaster = ""; model.cancelMaster() }
            }
            if model.masterError { Text("Incorrect master password.").font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
    }
    private func submitFallback() {
        let pw = fallbackMaster
        Task { await model.submitMaster(pw, gate: gate); if !model.awaitingMaster { fallbackMaster = "" } }
    }

    @ViewBuilder private var copyToast: some View {
        if let msg = model.copyConfirmation {
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.4)))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Bank Account edit (WF-17-style, TV-2c)

struct BankAccountEditView: View {
    let existing: StoredItem?
    @EnvironmentObject private var gate: VaultGate
    let onDone: () -> Void

    @State private var bankName = ""
    @State private var accountType = ""
    @State private var sortCode = ""
    @State private var accountNumber = ""
    @State private var swift = ""
    @State private var iban = ""
    @State private var pin = ""
    @State private var branchAddress = ""
    @State private var branchPhone = ""
    @State private var notes = ""
    @State private var rawBody = ""
    @State private var loaded = false
    @State private var savedWarning = false

    private var isNew: Bool { existing == nil }
    // Soft checks — computed live; they GUIDE only and never gate save.
    private var sortCodeCheck: FieldCheck { BankValidation.sortCode(sortCode) }
    private var accountCheck: FieldCheck { BankValidation.accountNumber(accountNumber) }
    private var swiftCheck: FieldCheck { BankValidation.swift(swift) }
    private var ibanCheck: FieldCheck { BankValidation.iban(iban) }
    private var pinCheck: FieldCheck { BankValidation.pin(pin) }
    private var anySuspect: Bool {
        sortCodeCheck.isSuspect || accountCheck.isSuspect || swiftCheck.isSuspect
            || ibanCheck.isSuspect || pinCheck.isSuspect
    }
    /// True when the loaded account type isn't one of the fixed options (an odd import) — kept selectable.
    private var accountTypeUnlisted: Bool { !accountType.isEmpty && !bankAccountTypes.contains(accountType) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "New Bank Account" : "Edit Bank Account").font(.title2).bold().padding(.bottom, 6)

                field("Bank name", $bankName, placeholder: "e.g. Barclays")
                accountTypePicker
                field("Sort code", $sortCode, placeholder: "XX-XX-XX", check: sortCodeCheck)
                field("Account number", $accountNumber, check: accountCheck)
                field("SWIFT / BIC", $swift, check: swiftCheck)
                field("IBAN", $iban, check: ibanCheck)
                field("PIN", $pin, check: pinCheck)
                field("Branch address", $branchAddress)
                field("Branch phone", $branchPhone)
                field("Notes", $notes)

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
            bankName = existing?.title ?? ""
            guard let b = existing.flatMap({ gate.decryptBankAccount($0) }) else { return }
            // Title is the user's item name; prefer the structured bank name when present.
            bankName = b.bankName.isEmpty ? (existing?.title ?? "") : b.bankName
            accountType = b.accountType; sortCode = b.sortCode; accountNumber = b.accountNumber
            swift = b.swift; iban = b.iban; pin = b.pin
            branchAddress = b.branchAddress; branchPhone = b.branchPhone; notes = b.notes
            rawBody = b.rawBody
        }
        .onDisappear { accountNumber = ""; iban = ""; pin = "" }   // drop entered secrets
    }

    private func save() async {
        let payload = BankAccountPayload(
            bankName: bankName, accountType: accountType, sortCode: sortCode,
            accountNumber: accountNumber, swift: swift, iban: iban, pin: pin,
            branchAddress: branchAddress, branchPhone: branchPhone, notes: notes, rawBody: rawBody
        )
        let title = bankName.trimmingCharacters(in: .whitespaces)
        await gate.saveBankAccount(id: existing?.id, title: title.isEmpty ? (existing?.title ?? "") : title,
                                   payload: payload)
        if anySuspect { savedWarning = true } else { onDone() }   // saved either way — warning never blocks
    }

    /// Account type is a PICKER (fixed list) so a NEW value can't be garbage; an imported value outside the
    /// list is preserved as its own selectable tag (the freeform fallback) so it's never trapped.
    private var accountTypePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("ACCOUNT TYPE").font(.caption).bold().foregroundStyle(.secondary)
            Picker(selection: $accountType) {
                Text("—").tag("")
                if accountTypeUnlisted { Text("\(accountType) (imported)").tag(accountType) }
                ForEach(bankAccountTypes, id: \.self) { Text($0).tag($0) }
            } label: { EmptyView() }
            .labelsHidden().pickerStyle(.menu)
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder private func field(_ title: String, _ text: Binding<String>,
                                    placeholder: String = "", check: FieldCheck = .ok) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).suspectBorder(check.isSuspect)
            ValidationHint(check: check)
        }
        .padding(.vertical, 7)
    }
}
