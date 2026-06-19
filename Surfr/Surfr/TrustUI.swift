import SwiftUI
import AppKit

/// Small green check badge marking a trusted host. Matches `CountBadge`'s size and
/// styling (bold white glyph, same font/padding, filled capsule) so the two badges
/// look like a set. Only shown when trusted — absence means untrusted (no untrusted
/// marker). Caller positions it.
struct TrustedBadge: View {
    var body: some View {
        // Use a text glyph (not the SF Symbol "checkmark", whose bounding box is
        // taller than a digit) so the badge's height matches `CountBadge` exactly —
        // same font/weight/padding/shape, just green with a ✓.
        Text("\u{2713}")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.green))
            .help("Trusted — stays logged in")
    }
}

/// Amber "not secure" badge for a host currently on an insecure (http) page. Same
/// corner/size language as `TrustedBadge` (the two are mutually exclusive — http
/// can't be trusted): a white ⚠-with-! glyph on a filled amber capsule.
struct InsecureBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 2.5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange))
            .help("Not secure — this page is loaded over an insecure (http) connection")
    }
}

/// One trust toast (slice C1 indicators, part 2). Shown only on the explicit
/// trust/untrust action, never on revisits to an already-trusted site.
struct TrustToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case trusting          // green confirmation: now trusting
        case untrusting        // neutral: stopped trusting
        case blockedInsecure   // amber warning: can't trust an http site
    }
    let id = UUID()
    /// The registrable domain (e.g. "google.com").
    let domain: String
    let kind: Kind
}

/// The toast overlay: favicon + message + (when trusting) the green badge, with a
/// ✕ for early dismissal. Loads the favicon like the rail/bookmark tiles.
struct TrustToastView: View {
    let toast: TrustToast
    let onClose: () -> Void

    @State private var iconData: Data?

    /// Use the registrable domain itself as the favicon host (its apex).
    private var host: String { toast.domain }

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                switch toast.kind {
                case .trusting:
                    Text("Now trusting \(toast.domain)")
                        .font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text("stays logged in")
                        .font(.caption2).foregroundStyle(.secondary)
                case .untrusting:
                    Text("Stopped trusting \(toast.domain)")
                        .font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text("session is now ephemeral")
                        .font(.caption2).foregroundStyle(.secondary)
                case .blockedInsecure:
                    Text("Can't trust an insecure site")
                        .font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text("Staying logged in needs a secure (HTTPS) connection")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            if toast.kind == .trusting { TrustedBadge() }

            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        // Amber border for the warning variant; subtle gray otherwise.
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(toast.kind == .blockedInsecure ? Color.orange.opacity(0.7) : Color.gray.opacity(0.2),
                          lineWidth: toast.kind == .blockedInsecure ? 1.5 : 1))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .frame(maxWidth: 320)
        // The whole toast is also click-to-dismiss.
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .task(id: host) { await loadIcon() }
    }

    /// Leading visual: an amber warning triangle for the blocked case, else the
    /// site favicon.
    @ViewBuilder private var leading: some View {
        if toast.kind == .blockedInsecure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
        } else {
            icon.clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var icon: some View {
        if let data = iconData ?? FaviconService.shared.cachedFaviconData(forHost: host),
           let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                FaviconTile.letterColor(for: host)
                Text(FaviconTile.letter(for: host))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func loadIcon() async {
        if let cached = FaviconService.shared.cachedFaviconData(forHost: host) {
            iconData = cached
            return
        }
        iconData = await FaviconService.shared.favicon(forHost: host)
    }
}
