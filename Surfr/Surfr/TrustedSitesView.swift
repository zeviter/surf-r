import SwiftUI
import Combine

/// Loads per-domain visit counts (summed across subdomains) for the trusted-sites
/// page. The trusted set itself lives in `TrustStore` (observed by the view);
/// this just augments each row with its aggregated visit count, fetched off-main.
@MainActor
final class TrustedSitesModel: ObservableObject {
    @Published private(set) var visitCounts: [String: Int] = [:]

    func loadCounts(for domains: [String]) async {
        var counts: [String: Int] = [:]
        for domain in domains {
            counts[domain] = await HistoryStore.shared.visitCount(forDomain: domain)
        }
        if Task.isCancelled { return }
        visitCounts = counts
    }
}

/// The Trusted Sites page (slice 8), rendered as an internal tab and built on the
/// shared `SearchFilterPage` so it matches the history page. Lists trusted domains
/// (most-recently-trusted first) with trusted-on date + aggregated visit count,
/// an Open action, and an untrust action that confirms the sign-out consequence.
struct TrustedSitesPage: View {
    /// Open a domain — always in a NEW tab.
    let onOpenURL: (URL) -> Void

    @ObservedObject private var trustStore = TrustStore.shared
    @StateObject private var model = TrustedSitesModel()
    @State private var query = ""

    private var allSites: [TrustStore.TrustedSite] { trustStore.trustedSites }

    private var filtered: [TrustStore.TrustedSite] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allSites }
        return allSites.filter { $0.domain.contains(q) }
    }

    private var sections: [PageSection<TrustStore.TrustedSite>] {
        filtered.isEmpty ? [] : [PageSection(id: "trusted", title: "Trusted", items: filtered)]
    }

    var body: some View {
        SearchFilterPage(
            title: "Trusted Sites",
            query: $query,
            searchPrompt: "Search trusted sites",
            sections: sections,
            emptyMessage: "No trusted sites yet",
            emptyHint: "Press ⌘⇧T to trust the site you're on — you'll stay logged in.",
            noResultsMessage: "No results",
            actions: {
                if !allSites.isEmpty {
                    Text("\(allSites.count) trusted site\(allSites.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            },
            row: { site in
                TrustedSiteRow(
                    site: site,
                    visitCount: model.visitCounts[site.domain],
                    onOpen: { open(site.domain) },
                    onUntrust: { trustStore.untrust(host: site.domain) }
                )
            }
        )
        // Refresh visit counts whenever the trusted set changes (e.g. after untrust).
        .task(id: allSites.map(\.domain).sorted().joined(separator: ",")) {
            await model.loadCounts(for: allSites.map(\.domain))
        }
    }

    private func open(_ domain: String) {
        guard let url = URL(string: "https://\(domain)") else { return }
        onOpenURL(url)
    }
}

/// One trusted-domain row: reuses `PageRow`, with trailing Open + untrust controls.
/// Untrust isn't a silent ✕ — it flips to an inline confirm that states the
/// sign-out consequence before removing the row.
struct TrustedSiteRow: View {
    let site: TrustStore.TrustedSite
    let visitCount: Int?
    let onOpen: () -> Void
    let onUntrust: () -> Void

    @State private var confirmingUntrust = false

    var body: some View {
        PageRow(
            host: site.domain,
            primary: site.domain,
            secondary: secondary,
            onOpen: onOpen
        ) {
            if confirmingUntrust {
                // Inline confirmation surfacing the consequence (sign-out).
                Text("Sign out?")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Untrust", role: .destructive) { onUntrust() }
                    .controlSize(.small)
                Button("Keep") { confirmingUntrust = false }
                    .controlSize(.small)
            } else {
                Button("Open", action: onOpen)
                    .controlSize(.small)
                Button { confirmingUntrust = true } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Stop trusting — signs you out of \(site.domain)")
            }
        }
    }

    private var secondary: String {
        let date = Self.dateFormatter.string(from: site.trustedOn)
        if let visitCount {
            return "Trusted \(date) · \(visitCount) visit\(visitCount == 1 ? "" : "s")"
        }
        return "Trusted \(date)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
