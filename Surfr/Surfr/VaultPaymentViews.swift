import SwiftUI
import AppKit
import Combine
import SurfrCore

// Generic card glyph (SF Symbols ships no card-brand logos, so the network is shown as text alongside a
// neutral card glyph — never a fake brand mark).
private let cardGlyph = "creditcard.fill"

// MARK: - Payment detail model — reuses the Slice-5 reveal/copy + biometric-gate machinery for the two
// sensitive fields (card number + CVV). No new reveal logic: the auth gate, master fallback, and
// concealed clipboard are the gate's; this only orchestrates them for two secrets.

@MainActor
final class PaymentDetailModel: ObservableObject {
    @Published private(set) var nickname = ""
    @Published private(set) var cardholderName = ""
    @Published private(set) var cardType = ""        // LastPass product string (a label, not the network)
    @Published private(set) var expiry = ""
    @Published private(set) var startDate = ""
    @Published private(set) var notes = ""
    @Published private(set) var last4 = ""
    @Published private(set) var network: CardNetwork = .unknown
    @Published private(set) var numberRevealed: String?   // nil = masked
    @Published private(set) var cvvRevealed: String?
    // Soft validation (TV-2-VAL): computed once at load (without revealing), so the detail can flag
    // already-imported junk in amber without decrypting on list-draw.
    @Published private(set) var numberCheck: FieldCheck = .ok
    @Published private(set) var cvvCheck: FieldCheck = .ok
    @Published private(set) var expiryCheck: FieldCheck = .ok
    @Published private(set) var loadFailed = false
    @Published var awaitingMaster = false
    @Published var masterError = false
    @Published var copyConfirmation: String?

    enum Field { case number, cvv }
    private enum Action { case reveal(Field), copy(Field) }
    private var pending: Action?

    private var number = WipeableSecret("")
    private var cvv = WipeableSecret("")
    private var copyClearTask: Task<Void, Never>?

    func load(_ item: StoredItem, gate: VaultGate) {
        guard let p = gate.decryptPayment(item) else { loadFailed = true; return }
        nickname = p.nickname.isEmpty ? item.title : p.nickname
        cardholderName = p.cardholderName
        cardType = p.cardType
        // Display the canonical MM/YYYY; keep the raw only if it can't be parsed (then it's flagged).
        expiry = CardValidation.canonicalMonthYear(p.expiry).ifEmpty(p.expiry)
        startDate = CardValidation.canonicalMonthYear(p.startDate).ifEmpty(p.startDate)
        notes = p.notes
        number = WipeableSecret(p.number)
        cvv = WipeableSecret(p.cvv)
        numberCheck = CardValidation.cardNumber(p.number)               // flag junk without revealing
        cvvCheck = CardValidation.cvv(p.cvv)
        expiryCheck = CardValidation.expiry(p.expiry)
        last4 = item.last4 ?? CardDetection.last4(p.number)              // cleartext hint preferred
        network = item.cardNetwork != nil ? CardNetwork.from(hint: item.cardNetwork)
                                          : CardDetection.network(p.number)
    }

    var hasNumber: Bool { !number.isEmpty }
    var hasCVV: Bool { !cvv.isEmpty }
    var maskedNumber: String {
        if let r = numberRevealed { return r }
        return last4.isEmpty ? "••••" : "•••• •••• •••• \(last4)"
    }
    var maskedCVV: String { cvvRevealed ?? "•••" }

    func concealNumber() { numberRevealed = nil }
    func concealCVV() { cvvRevealed = nil }

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

    private func perform(_ action: Action) {
        switch action {
        case .reveal(.number): numberRevealed = number.reveal()
        case .reveal(.cvv):    cvvRevealed = cvv.reveal()
        case .copy(.number):   VaultClipboard.copyConcealed(number.reveal()); noteCopied("Card number")
        case .copy(.cvv):      VaultClipboard.copyConcealed(cvv.reveal());    noteCopied("Security code")
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

    /// Zero both secrets + clear all decrypted fields (called on disappear) — same lifetime discipline
    /// as the password field.
    func wipe() {
        number.wipe(); cvv.wipe()
        numberRevealed = nil; cvvRevealed = nil
        nickname = ""; cardholderName = ""; cardType = ""; expiry = ""; startDate = ""; notes = ""
        awaitingMaster = false; masterError = false; pending = nil
    }

    var secretsWipedForTest: Bool { number.isWiped && cvv.isWiped }
}

// MARK: - Payment detail (WF-17)

struct PaymentDetailView: View {
    let item: StoredItem
    @EnvironmentObject private var gate: VaultGate
    let onEdit: () -> Void
    let onDelete: () -> Void

    @StateObject private var model = PaymentDetailModel()
    @State private var confirmingDelete = false
    @State private var fallbackMaster = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Image(systemName: cardGlyph).font(.system(size: 30)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.nickname.isEmpty ? "Card" : model.nickname).font(.title2).bold()
                        if model.network != .unknown || !model.last4.isEmpty {
                            Text("\(model.network.displayName) ···· \(model.last4)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 6)

                if model.loadFailed {
                    Label("Couldn’t decrypt this item.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else {
                    if model.hasNumber { secretField("Card number", value: model.maskedNumber, field: .number,
                                                     revealed: model.numberRevealed != nil, check: model.numberCheck) }
                    if model.hasCVV { secretField("Security code", value: model.maskedCVV, field: .cvv,
                                                  revealed: model.cvvRevealed != nil, check: model.cvvCheck) }
                    if model.awaitingMaster { masterFallback }
                    plainField("Cardholder", model.cardholderName)
                    plainField("Expiry", model.expiry, check: model.expiryCheck)
                    plainField("Valid from", model.startDate)
                    plainField("Card type", model.cardType)     // the LastPass product label
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
        .confirmationDialog("Delete this card?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// A masked, biometric-gated sensitive field (card number / CVV) — reveal + copy both gated. A
    /// `.suspect` check flags it amber + a hint (soft; never blocks).
    private func secretField(_ label: String, value: String, field: PaymentDetailModel.Field,
                             revealed: Bool, check: FieldCheck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    if revealed { field == .number ? model.concealNumber() : model.concealCVV() }
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

    /// A non-sensitive field, shown plainly with a concealed-clipboard copy; omitted when empty. An
    /// optional `.suspect` check flags it (e.g. an imported junk expiry).
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

// MARK: - Payment edit (WF-17)

struct PaymentEditView: View {
    let existing: StoredItem?
    @EnvironmentObject private var gate: VaultGate
    let onDone: () -> Void

    @State private var nickname = ""
    @State private var cardholderName = ""
    @State private var numberField = ""          // digits, grouped into 4s for display
    @State private var cvvField = ""             // digits only, max 4
    @State private var cardTypeStored = ""       // LastPass product label — preserved, not edited
    @State private var notes = ""
    @State private var rawBody = ""
    // Structured expiry / valid-from (pickers); `*Raw` holds the original (preserved if not re-picked).
    @State private var expMonth: Int?
    @State private var expYear: Int?
    @State private var expRaw = ""
    @State private var vfMonth: Int?
    @State private var vfYear: Int?
    @State private var vfRaw = ""
    @State private var loaded = false
    @State private var savedWarning = false

    private var isNew: Bool { existing == nil }
    private var detectedNetwork: CardNetwork { CardDetection.network(numberField) }
    private var savedExpiry: String { monthYear(expMonth, expYear) ?? expRaw }
    private var savedValidFrom: String { monthYear(vfMonth, vfYear) ?? vfRaw }
    private var numberCheck: FieldCheck { CardValidation.cardNumber(numberField) }
    private var cvvCheck: FieldCheck { CardValidation.cvv(cvvField) }
    private var anySuspect: Bool {
        numberCheck.isSuspect || cvvCheck.isSuspect
            || CardValidation.expiry(savedExpiry).isSuspect || CardValidation.expiry(savedValidFrom).isSuspect
    }

    private func monthYear(_ m: Int?, _ y: Int?) -> String? {
        guard let m, let y else { return nil }
        return String(format: "%02d/%04d", m, y)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "New Payment Method" : "Edit Payment Method").font(.title2).bold().padding(.bottom, 6)

                field("Nickname", $nickname, placeholder: "e.g. Premier Debit")
                field("Cardholder name", $cardholderName)

                // Card number — digits/spaces only, auto-grouped; Luhn WARNS but never blocks.
                VStack(alignment: .leading, spacing: 5) {
                    Text("CARD NUMBER").font(.caption).bold().foregroundStyle(.secondary)
                    TextField("•••• •••• •••• ••••", text: $numberField)
                        .textFieldStyle(.roundedBorder).suspectBorder(numberCheck.isSuspect)
                        .onChange(of: numberField) { _, v in
                            // Digits-only, grouped in 4s, soft-capped at 19 (longest real PAN — matches
                            // how CVV stops at 4). A no-digit junk import is left visible so it isn't
                            // wiped; once the user types a digit it normalizes.
                            guard !CardDetection.digits(v).isEmpty else { return }
                            let g = CardDetection.grouped(String(CardDetection.digits(v).prefix(19)))
                            if g != v { numberField = g }
                        }
                    HStack {
                        // Network = prefix detection, read-only (never a free-text card-type box).
                        Text(detectedNetwork == .unknown ? "Card network: —" : "Card network: \(detectedNetwork.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ValidationHint(check: numberCheck)
                }
                .padding(.vertical, 7)

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SECURITY CODE").font(.caption).bold().foregroundStyle(.secondary)
                        TextField("•••", text: $cvvField)
                            .textFieldStyle(.roundedBorder).suspectBorder(cvvCheck.isSuspect)
                            .onChange(of: cvvField) { _, v in
                                let d = String(CardDetection.digits(v).prefix(4))
                                if d != v { cvvField = d }
                            }
                        ValidationHint(check: cvvCheck)
                    }
                    .padding(.vertical, 7)
                    MonthYearPicker(label: "Expiry", month: $expMonth, year: $expYear,
                                    rawWasSuspect: CardValidation.expiry(expRaw).isSuspect)
                }
                MonthYearPicker(label: "Valid from", month: $vfMonth, year: $vfYear,
                                rawWasSuspect: CardValidation.expiry(vfRaw).isSuspect)

                if !cardTypeStored.isEmpty {
                    Text("Imported card type: \(cardTypeStored)").font(.caption).foregroundStyle(.tertiary).padding(.vertical, 4)
                }
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
            guard let p = existing.flatMap({ gate.decryptPayment($0) }) else {
                nickname = existing?.title ?? ""; return
            }
            nickname = p.nickname.isEmpty ? (existing?.title ?? "") : p.nickname
            cardholderName = p.cardholderName
            // Preserve a non-digit (junk) number so editing other fields doesn't wipe it; valid numbers group.
            numberField = CardDetection.digits(p.number).isEmpty ? p.number : CardDetection.grouped(p.number)
            cvvField = CardDetection.digits(p.cvv)
            cardTypeStored = p.cardType; notes = p.notes; rawBody = p.rawBody
            expRaw = p.expiry; vfRaw = p.startDate
            if let my = CardValidation.parseMonthYear(p.expiry) { expMonth = my.month; expYear = my.year }
            if let my = CardValidation.parseMonthYear(p.startDate) { vfMonth = my.month; vfYear = my.year }
        }
        .onDisappear { numberField = ""; cvvField = "" }   // drop entered secrets
    }

    private func save() async {
        // Preserve a junk (no-digit) number rather than wiping it; otherwise store digits only. All other
        // payload fields (incl. rawBody + the imported cardType) are carried through untouched.
        let savedNumber = CardDetection.digits(numberField).isEmpty ? numberField : CardDetection.digits(numberField)
        let payload = PaymentPayload(nickname: nickname, cardholderName: cardholderName,
                                     number: savedNumber, cardType: cardTypeStored,
                                     expiry: savedExpiry, startDate: savedValidFrom, cvv: cvvField,
                                     notes: notes, rawBody: rawBody)
        await gate.savePayment(id: existing?.id, title: nickname.trimmingCharacters(in: .whitespaces), payload: payload)
        if anySuspect { savedWarning = true } else { onDone() }   // saved either way — warning never blocks
    }

    @ViewBuilder private func field(_ title: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 7)
    }
}
