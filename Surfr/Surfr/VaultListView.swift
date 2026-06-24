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

    var body: some View {
        content
            // Restore where the user was (search + open item) after navigate-away recreated the surface.
            .onAppear {
                query = gate.savedVaultQuery
                if let id = gate.savedVaultOpenItemID, gate.items.contains(where: { $0.id == id }) {
                    nav = VaultNav(); nav.push(.detail(id)); restoredItem = true
                }
            }
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
            // ⌘F focuses the search field.
            .background {
                Button("") { searchFocusToken += 1 }
                    .keyboardShortcut("f", modifiers: .command).opacity(0)
            }
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

    /// One ESC: clear an active search field first (consuming that press), otherwise behave as Back.
    private func escape() {
        switch nav.current {
        case .none where !query.isEmpty:            query = ""; return     // list search
        case .securityCheck where !scQuery.isEmpty: scQuery = ""; return   // Security Check search
        default: goBack()
        }
    }

    @ViewBuilder private var content: some View {
        switch nav.current {
        case .none:
            listPage
        case .detail(let id):
            if let item = gate.items.first(where: { $0.id == id }) {
                detailScaffold {
                    VaultItemView(item: item,
                                  onEdit: { nav.push(.edit(id)) },
                                  onDelete: { Task { await gate.deleteItem(id); nav.pop() } })
                }
            } else { fallbackToList }
        case .edit(let id):
            detailScaffold {
                VaultEditView(existing: id.flatMap { gid in gate.items.first { $0.id == gid } }) {
                    nav.pop()
                }
            }
        case .securityCheck:
            detailScaffold {
                SecurityCheckView(query: $scQuery, onOpenItem: { nav.push(.edit($0)) })
            }
        }
    }

    private var fallbackToList: some View { Color.clear.onAppear { _ = nav.pop() } }

    // MARK: - List (WF-4)

    private var listPage: some View {
        VStack(spacing: 0) {
            SearchFilterPage(
                title: "Vault",
                query: $query,
                searchPrompt: "Search logins",
                sections: sections,
                emptyMessage: "No logins yet",
                emptyHint: "Add one with the + button.",
                noResultsMessage: "No matching logins",
                searchFocusToken: searchFocusToken,
                actions: {
                    Button { nav.push(.securityCheck) } label: { Image(systemName: "checkmark.shield") }
                        .help("Security check — weak, reused, and 2FA-available logins")
                        .disabled(gate.items.isEmpty)
                    Button { nav.push(.edit(nil)) } label: { Image(systemName: "plus") }
                        .help("Add a login")
                },
                row: { item in
                    PageRow(host: item.hosts.first?.host ?? "",
                            primary: item.title.isEmpty ? (item.hosts.first?.host ?? "Login") : item.title,
                            secondary: item.hosts.first?.host,
                            onOpen: { nav.push(.detail(item.id)) }) {
                        healthBadge(for: item)
                    }
                }
            )
            Divider()
            securityBar   // security-relevant controls stay VISIBLE with their state (not in a menu)
        }
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

    private var sections: [PageSection<StoredItem>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? gate.items : gate.items.filter {
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
