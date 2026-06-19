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

/// One trust toast (slice C1 indicators, part 2). Shown only on the explicit
/// trust/untrust action, never on revisits to an already-trusted site.
struct TrustToast: Identifiable, Equatable {
    let id = UUID()
    /// The trusted registrable domain (e.g. "google.com").
    let domain: String
    /// true → "Now trusting …"; false → "Stopped trusting …".
    let trusting: Bool
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
            icon
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                if toast.trusting {
                    Text("Now trusting \(toast.domain)")
                        .font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text("stays logged in")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Stopped trusting \(toast.domain)")
                        .font(.callout).fontWeight(.semibold).lineLimit(1)
                    Text("session is now ephemeral")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if toast.trusting { TrustedBadge() }

            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.2)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .frame(maxWidth: 320)
        // The whole toast is also click-to-dismiss.
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .task(id: host) { await loadIcon() }
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
