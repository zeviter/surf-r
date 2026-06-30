import SwiftUI
import AppKit
import SurfrCore

/// The vault surface (rail key icon / ⌘⇧V → unlocked). Reflects live session state: a locked card
/// when locked (immediate feedback after Lock), the list when unlocked.
struct VaultSurface: View {
    @EnvironmentObject private var gate: VaultGate

    var body: some View {
        Group {
            if gate.phase == .locked {
                lockedCard
            } else {
                VaultListView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        // Mirror true biometric state and (re)load items whenever the surface appears.
        .task {
            gate.refreshBiometricState()
            await gate.loadItems()
        }
    }

    private var lockedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Vault locked").font(.title2).bold()
            Text("Your vault is locked. Unlock to view your logins.")
                .font(.callout).foregroundStyle(.secondary)
            Button { NotificationCenter.default.post(name: .openVault, object: nil) } label: {
                Label("Unlock", systemImage: "lock.open.fill")
            }
            .buttonStyle(.borderedProminent).padding(.top, 6)
        }
    }
}

struct VaultListView: View {
    @EnvironmentObject private var gate: VaultGate

    @State private var nav = VaultNav()
    @State private var query = ""
    @State private var scQuery = ""           // Security Check search (lifted so ESC can clear it first)
    @State private var regeneratedCode: String?
    @State private var searchFocusToken = 0
    @StateObject private var importer = ImportCoordinator()
    @StateObject private var totpImporter = TOTPImportCoordinator()

    @State private var restoredItem = false
    @State private var segment: Segment = .passwords    // WF-12; persisted for the session via the gate
    @State private var showTypePicker = false           // WF-13 add-new overlay

    /// The four typed-vault segments (WF-12). Each maps to a `VaultItemType`; the list source, search
    /// prompt, empty message, and row glyph follow the selection.
    private enum Segment: String, CaseIterable, Identifiable {
        case passwords, notes, addresses, payment, bank
        var id: String { rawValue }
        var title: String {
            switch self {
            case .passwords: return "Passwords"; case .notes: return "Notes"
            case .addresses: return "Addresses"; case .payment: return "Payment"; case .bank: return "Bank"
            }
        }
        var type: String {
            switch self {
            case .passwords: return VaultItemType.login;   case .notes: return VaultItemType.secureNote
            case .addresses: return VaultItemType.address; case .payment: return VaultItemType.payment
            case .bank: return VaultItemType.bankAccount
            }
        }
        var rowGlyph: String {
            switch self {
            case .passwords: return ""; case .notes: return "note.text"
            case .addresses: return "mappin.and.ellipse"; case .payment: return "creditcard"
            case .bank: return "building.columns"
            }
        }
        var emptyMessage: String {
            switch self {
            case .passwords: return "No logins yet"; case .notes: return "No secure notes yet"
            case .addresses: return "No addresses yet"; case .payment: return "No payment methods yet"
            case .bank: return "No bank accounts yet"
            }
        }
        var searchPrompt: String {
            switch self {
            case .passwords: return "Search logins"; case .notes: return "Search notes"
            case .addresses: return "Search addresses"; case .payment: return "Search cards"
            case .bank: return "Search bank accounts"
            }
        }
        static func from(type: String) -> Segment { Segment.allCases.first { $0.type == type } ?? .passwords }
    }

    var body: some View {
        content
            // Restore where the user was (segment + search + open item) after navigate-away recreated
            // the surface (it's ephemeral).
            .onAppear {
                query = gate.savedVaultQuery
                segment = .from(type: gate.savedVaultSegment)
                if let id = gate.savedVaultOpenItemID, gate.items.contains(where: { $0.id == id }) {
                    nav = VaultNav(); nav.push(.detail(id)); restoredItem = true
                }
            }
            .onChange(of: segment) { _, s in gate.savedVaultSegment = s.type }
            .onChange(of: gate.items) { _, items in   // open item may only be available after async load
                guard !restoredItem, nav.atRoot, let id = gate.savedVaultOpenItemID,
                      items.contains(where: { $0.id == id }) else { return }
                restoredItem = true; nav.push(.detail(id))
            }
            .onChange(of: query) { _, q in gate.savedVaultQuery = q }
            .onChange(of: nav) { _, n in gate.savedVaultOpenItemID = n.openItemID }
            // Back-nav inside the vault: ⌘← (menu) and ⌘[ / swipe / side-button (routed via .goBack
            // for internal surfaces) pop one level; at the list root they close the vault surface.
            .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in goBack() }
            // ESC: clear an active search first (one press), then pop one level, then close the surface.
            // Uses a window-level key catcher so it works regardless of which control holds focus
            // (the editor's Cancel button keeps its own .cancelAction; both pop one level, no double).
            .background(EscapeCatcher { escape() })
            // ⌘F focuses the vault search field. C2 routes ⌘F by surface (the global menu shortcut would
            // otherwise shadow this), posting `.focusVaultSearch` when the vault is the active surface.
            .onReceive(NotificationCenter.default.publisher(for: .focusVaultSearch)) { _ in searchFocusToken += 1 }
            // ONE sheet modifier — multiple `.sheet`s on a single view conflict in SwiftUI (the 3rd
            // broke the TOTP done/failed phases from rendering: missing delete prompt / no error).
            .sheet(item: Binding(get: { activeSheet }, set: { if $0 == nil { dismissSheets() } })) { sheet in
                switch sheet {
                case .regenerate(let code): RegeneratedKitSheet(code: code) { regeneratedCode = nil }
                case .csvImport: VaultImportSheet(coordinator: importer)
                case .totpImport: TOTPImportSheet(coordinator: totpImporter)
                }
            }
    }

    private enum ActiveSheet: Identifiable {
        case regenerate(String), csvImport, totpImport
        var id: String {
            switch self {
            case .regenerate: return "regenerate"
            case .csvImport:  return "csvImport"
            case .totpImport: return "totpImport"
            }
        }
    }

    private var activeSheet: ActiveSheet? {
        if let code = regeneratedCode { return .regenerate(code) }
        if importer.isActive { return .csvImport }
        if totpImporter.isActive { return .totpImport }
        return nil
    }

    private func dismissSheets() {
        regeneratedCode = nil
        importer.finish()
        totpImporter.finish()
    }

    /// One Back: pop a level; at the list root, close the vault surface (→ the tab you came from),
    /// consistent with the ephemeral-internal-surface rule.
    private func goBack() {
        if !nav.pop() { NotificationCenter.default.post(name: .closeVaultSurface, object: nil) }
    }

    /// One ESC: dismiss the type picker first, else clear an active search field (consuming that
    /// press), otherwise behave as Back.
    private func escape() {
        if showTypePicker { showTypePicker = false; return }   // overlay = top of stack
        switch nav.current {
        case .none where !query.isEmpty:            query = ""; return     // list search
        case .securityCheck where !scQuery.isEmpty: scQuery = ""; return   // Security Check search
        default: goBack()
        }
    }

    @ViewBuilder private var content: some View {
        mainContent
            .overlay {
                if showTypePicker {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { showTypePicker = false }
                        TypePickerView(
                            onSelect: { choice in
                                showTypePicker = false
                                switch choice {
                                case .login:       nav.push(.editLogin(nil))
                                case .note:        nav.push(.editNote(nil))
                                case .address:     nav.push(.editAddress(nil))
                                case .payment:     nav.push(.editPayment(nil))
                                case .bankAccount: nav.push(.editBankAccount(nil))
                                }
                            },
                            onCancel: { showTypePicker = false }
                        )
                    }
                }
            }
    }

    @ViewBuilder private var mainContent: some View {
        switch nav.current {
        case .none:
            listPage
        case .detail(let id):
            detailFor(id)
        case .editLogin(let id):
            detailScaffold { VaultEditView(existing: lookup(id)) { nav.pop() } }
        case .editNote(let id):
            detailScaffold { SecureNoteEditView(existing: lookup(id)) { nav.pop() } }
        case .editAddress(let id):
            detailScaffold { AddressEditView(existing: lookup(id)) { nav.pop() } }
        case .editPayment(let id):
            detailScaffold { PaymentEditView(existing: lookup(id)) { nav.pop() } }
        case .editBankAccount(let id):
            detailScaffold { BankAccountEditView(existing: lookup(id)) { nav.pop() } }
        case .securityCheck:
            detailScaffold { SecurityCheckView(query: $scQuery, onOpenItem: { nav.push(.editLogin($0)) }) }
        }
    }

    private func lookup(_ id: UUID?) -> StoredItem? { id.flatMap { gid in gate.items.first { $0.id == gid } } }

    /// Type-dispatched detail: login / secure note / address get their own view; payment shows the
    /// honest interim placeholder until TV-2b.
    @ViewBuilder private func detailFor(_ id: UUID) -> some View {
        if let item = gate.items.first(where: { $0.id == id }) {
            let del: () -> Void = { Task { await gate.deleteItem(id); nav.pop() } }
            detailScaffold {
                switch item.type {
                case VaultItemType.secureNote:
                    SecureNoteDetailView(item: item, onEdit: { nav.push(.editNote(id)) }, onDelete: del)
                case VaultItemType.address:
                    AddressDetailView(item: item, onEdit: { nav.push(.editAddress(id)) }, onDelete: del)
                case VaultItemType.payment:
                    PaymentDetailView(item: item, onEdit: { nav.push(.editPayment(id)) }, onDelete: del)
                case VaultItemType.bankAccount:
                    BankAccountDetailView(item: item, onEdit: { nav.push(.editBankAccount(id)) }, onDelete: del)
                case VaultItemType.login:
                    VaultItemView(item: item, onEdit: { nav.push(.editLogin(id)) }, onDelete: del)
                default:
                    TypedInterimView(item: item, onDelete: del)   // defensive: only a reserved/future type (e.g. passkey)
                }
            }
        } else { fallbackToList }
    }

    private var fallbackToList: some View { Color.clear.onAppear { _ = nav.pop() } }

    // MARK: - List (WF-12 — segmented by type)

    private var listPage: some View {
        VStack(spacing: 0) {
            SearchFilterPage(
                title: "Vault",
                query: $query,
                searchPrompt: segment.searchPrompt,
                sections: typedSections,
                emptyMessage: segment.emptyMessage,
                emptyHint: "Add one with the + button.",
                noResultsMessage: "No matches",
                searchFocusToken: searchFocusToken,
                headerAccessory: AnyView(segmentedControl),
                actions: {
                    Button { nav.push(.securityCheck) } label: { Image(systemName: "checkmark.shield") }
                        .help("Security check — weak, reused, and 2FA-available logins")
                        .disabled(count(.passwords) == 0)
                    Button { showTypePicker = true } label: { Image(systemName: "plus") }
                        .help("Add an item")
                },
                row: { item in typedRow(item) }
            )
            Divider()
            securityBar   // security-relevant controls stay VISIBLE with their state (not in a menu)
        }
    }

    /// The WF-12 segmented control — surf-r vocabulary, **system-accent tracking** (`Color.accentColor`,
    /// never a hardcoded blue): a rounded neutral container with quiet dividers. The **active** segment is
    /// the coloured one — **accent title** + an **accent count pill with a white number**. **Inactive**
    /// segments go fully **grey** — grey title + grey pill + grey number — so they recede. No filled slab.
    private var segmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(Array(Segment.allCases.enumerated()), id: \.element.id) { index, seg in
                if index > 0 { Divider().frame(height: 14).opacity(0.5) }
                segmentButton(seg)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.gray.opacity(0.18)))
    }

    private func segmentButton(_ seg: Segment) -> some View {
        let active = segment == seg
        return Button { segment = seg } label: {
            HStack(spacing: 6) {
                Text(seg.title)
                    .font(.callout).fontWeight(active ? .semibold : .regular)
                    .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                countPill(count(seg), active: active)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The count pill (smaller than the title). **Active** → **accent** fill with a **white** number
    /// (matches the lit accent title). **Inactive** → fully **grey** (grey fill + grey number) so the
    /// whole segment recedes. The accent is the system accent.
    private func countPill(_ n: Int, active: Bool) -> some View {
        Text("\(n)")
            .font(.caption2).fontWeight(.semibold).monospacedDigit()
            .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(active ? Color.accentColor : Color.secondary.opacity(0.18)))
    }

    private func count(_ seg: Segment) -> Int { gate.items.lazy.filter { $0.type == seg.type }.count }

    /// Rows per the active segment. Passwords keep the favicon + host + health badge; the typed segments
    /// use a generic glyph + title (label/nickname). **No payload is decrypted to draw a row** — the
    /// Slice-5 zero-decryption-list invariant holds across all four segments.
    @ViewBuilder private func typedRow(_ item: StoredItem) -> some View {
        switch segment {
        case .passwords:
            PageRow(host: item.hosts.first?.host ?? "",
                    primary: item.title.isEmpty ? (item.hosts.first?.host ?? "Login") : item.title,
                    secondary: item.hosts.first?.host,
                    onOpen: { nav.push(.detail(item.id)) }) { healthBadge(for: item) }
        case .payment:
            // Glyph + nickname + "•••• last4" — all from the cleartext hint; NO payload decrypt (WF-12).
            PageRow(host: "",
                    primary: item.title.isEmpty ? "Card" : item.title,
                    secondary: paymentRowSubtitle(item),
                    leadingSystemImage: segment.rowGlyph,
                    onOpen: { nav.push(.detail(item.id)) }) { EmptyView() }
        case .bank:
            // Glyph + name + "•••• account-last4" — from the cleartext hint; NO payload decrypt (WF-12).
            PageRow(host: "",
                    primary: item.title.isEmpty ? "Bank account" : item.title,
                    secondary: bankRowSubtitle(item),
                    leadingSystemImage: segment.rowGlyph,
                    onOpen: { nav.push(.detail(item.id)) }) { EmptyView() }
        default:
            PageRow(host: "",
                    primary: item.title.isEmpty ? "Untitled" : item.title,
                    secondary: nil,
                    leadingSystemImage: segment.rowGlyph,
                    onOpen: { nav.push(.detail(item.id)) }) { EmptyView() }
        }
    }

    /// Payment row subtitle from the **cleartext** hint (network + last-4) — never decrypts the payload.
    private func paymentRowSubtitle(_ item: StoredItem) -> String? {
        let net = CardNetwork.from(hint: item.cardNetwork)
        let last4 = item.last4 ?? ""
        let parts = [net == .unknown ? nil : net.displayName,
                     last4.isEmpty ? nil : "•••• \(last4)"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// Bank row subtitle from the **cleartext** account-last-4 hint — never decrypts the payload (TV-2c).
    private func bankRowSubtitle(_ item: StoredItem) -> String? {
        let last4 = item.accountLast4 ?? ""
        return last4.isEmpty ? nil : "•••• \(last4)"
    }

    /// Visible, stateful security controls (per review): Touch ID status/toggle in the green/amber
    /// vocabulary, Regenerate Recovery Kit, and Lock — never hidden behind a ••• menu.
    private var securityBar: some View {
        HStack(spacing: 16) {
            if gate.biometricAvailable {
                TouchIDStatusRow(gate: gate)
            }
            // Same control kind as Touch ID: a switch with a state-coloured leading icon.
            Toggle(isOn: $gate.requireAuthToReveal) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(gate.requireAuthToReveal ? .green : .secondary)
                    Text("Require auth to reveal/copy/fill")
                }
            }
            .toggleStyle(.switch).tint(.green)
            .help("Require Touch ID or your master password before revealing or copying a password")

            Spacer()

            Button { importer.pickAndParse() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                .help("Import logins from a LastPass / Bitwarden / Chrome / Safari CSV export")

            Button { totpImporter.pickImage(gate: gate) } label: { Label("Import 2FA…", systemImage: "qrcode") }
                .help("Import one-time codes from a Google Authenticator export QR (or otpauth:// link)")

            Button {
                Task { regeneratedCode = await gate.regenerateRecoveryKit() }
            } label: { Label("Regenerate Recovery Key", systemImage: "arrow.triangle.2.circlepath") }
                .help("Generate a new recovery code (and Recovery Kit) — your old code stops working")
                .disabled(gate.isWorking)

            // State-aware lock control (the list only shows while unlocked, but keep it honest).
            Button {
                if gate.phase == .unlocked { gate.lockNow() }
                else { NotificationCenter.default.post(name: .openVault, object: nil) }
            } label: {
                Label(gate.phase == .unlocked ? "Lock Vault" : "Unlock Vault",
                      systemImage: gate.phase == .unlocked ? "lock.fill" : "lock.open.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    /// WF-4 health badge — rendered from **cached** signals with NO decryption: intrinsic flags come
    /// from `item.healthFlags`, reuse from the grouped keyed tokens in `gate.reusedItemIDs`. Preserves
    /// the Slice-5 zero-decryption list property.
    @ViewBuilder private func healthBadge(for item: StoredItem) -> some View {
        let flags = item.isLogin ? HealthFlags(rawValue: item.healthFlags) : []
        let reused = item.isLogin && gate.reusedItemIDs.contains(item.id)
        HStack(spacing: 5) {
            if flags.contains(.weak) || reused {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(flags.contains(.weak) && reused ? "Weak and reused password"
                          : (flags.contains(.weak) ? "Weak password" : "Reused password"))
            }
            if flags.contains(.twoFAAvailable) {
                Image(systemName: "lock.shield").foregroundStyle(.blue).help("Two-factor available for this site")
            }
            if flags.contains(.junkHost) {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("Needs attention — no usable website")
            }
        }
    }

    /// Sections for the ACTIVE segment, filtered by title/host only (never decrypting a payload to
    /// search — note bodies / address PII / card fields are not searchable).
    private var typedSections: [PageSection<StoredItem>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inSegment = gate.items.filter { $0.type == segment.type }
        let filtered = q.isEmpty ? inSegment : inSegment.filter {
            $0.title.lowercased().contains(q) || $0.hosts.contains { $0.host.lowercased().contains(q) }
        }
        let grouped = Dictionary(grouping: filtered) { (item: StoredItem) -> String in
            let label = item.title.isEmpty ? (item.hosts.first?.host ?? "#") : item.title
            let initial = label.first.map { String($0).uppercased() } ?? "#"
            return (initial.first?.isLetter ?? false) ? initial : "#"
        }
        return grouped.keys.sorted().map { key in
            PageSection(id: key, title: key,
                        items: grouped[key]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    // MARK: - Detail/edit chrome (manual back, no NavigationStack double-chrome)

    private func detailScaffold<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
