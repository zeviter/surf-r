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

    private enum Mode: Equatable { case list, detail(UUID), edit(UUID?) }
    @State private var mode: Mode = .list
    @State private var query = ""
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
                    mode = .detail(id); restoredItem = true
                }
            }
            .onChange(of: gate.items) { _, items in   // open item may only be available after async load
                guard !restoredItem, mode == .list, let id = gate.savedVaultOpenItemID,
                      items.contains(where: { $0.id == id }) else { return }
                restoredItem = true; mode = .detail(id)
            }
            .onChange(of: query) { _, q in gate.savedVaultQuery = q }
            .onChange(of: mode) { _, m in
                switch m {
                case .detail(let id): gate.savedVaultOpenItemID = id
                case .edit(let id): gate.savedVaultOpenItemID = id
                case .list: gate.savedVaultOpenItemID = nil
                }
            }
            // Back-nav inside the vault: ⌘← (menu) and ⌘[ / swipe / side-button (routed via .goBack
            // for internal surfaces) all pop detail/edit → list.
            .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in goBack() }
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

    private func goBack() {
        switch mode {
        case .list: break
        case .detail: mode = .list
        case .edit(let id): mode = id == nil ? .list : .detail(id!)
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .list:
            listPage
        case .detail(let id):
            if let item = gate.items.first(where: { $0.id == id }) {
                detailScaffold(title: item.title.isEmpty ? "Login" : item.title) {
                    VaultItemView(item: item,
                                  onEdit: { mode = .edit(id) },
                                  onDelete: { Task { await gate.deleteItem(id); mode = .list } })
                }
            } else { fallbackToList }
        case .edit(let id):
            detailScaffold(title: id == nil ? "New Login" : "Edit Login") {
                VaultEditView(existing: id.flatMap { gid in gate.items.first { $0.id == gid } }) {
                    mode = id == nil ? .list : .detail(id!)
                }
            }
        }
    }

    private var fallbackToList: some View { Color.clear.onAppear { mode = .list } }

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
                    Button { mode = .edit(nil) } label: { Image(systemName: "plus") }
                        .help("Add a login")
                },
                row: { item in
                    PageRow(host: item.hosts.first?.host ?? "",
                            primary: item.title.isEmpty ? (item.hosts.first?.host ?? "Login") : item.title,
                            secondary: item.hosts.first?.host,
                            onOpen: { mode = .detail(item.id) }) {
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

    @ViewBuilder private func healthBadge(for item: StoredItem) -> some View {
        // Health flags are computed in Slice 9; for now only the (green) baseline shows.
        if item.healthFlags != 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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

    private func detailScaffold<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { mode = .list } label: { Label("Vault", systemImage: "chevron.left") }
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
