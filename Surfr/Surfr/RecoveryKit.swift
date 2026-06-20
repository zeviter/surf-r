import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The printable Recovery Kit (WF-10 / vault-spec §5). Rendered on US-Letter, shown on the kit step
/// and saved/printed only by explicit user action. The recovery code and a blank line for the master
/// password are the load-bearing content; the copy is deliberately blunt about there being no backstop.
struct RecoveryKitDocument: View {
    let code: String
    let createdAt: Date

    private var dateString: String {
        let f = DateFormatter(); f.dateStyle = .long; f.timeStyle = .none
        return f.string(from: createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("surf-r Recovery Kit").font(.system(size: 26, weight: .bold))
                Text("Created \(dateString)").font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY CODE").font(.caption).bold().foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.35)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MASTER PASSWORD").font(.caption).bold().foregroundStyle(.secondary)
                Text("Write it here, or store it somewhere only you can reach:")
                    .font(.callout).foregroundStyle(.secondary)
                Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1).padding(.top, 18)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("READ THIS").font(.caption).bold().foregroundStyle(.red)
                Text("There is no backstop. This kit is the only way back into your vault if you forget your master password — there is no server, no reset, no support line that can recover it.")
                Text("Anyone who has this recovery code **and** access to your device can open your vault. Keep this page offline and private; do not photograph it into a cloud library.")
                Text("If you lose **both** your master password and this kit, your vault is permanently unrecoverable — by design.")
            }
            .font(.callout)

            Spacer(minLength: 0)
            Text("surf-r stores nothing about you. This page was generated on your device and is not saved anywhere unless you save or print it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(width: 612, height: 792, alignment: .topLeading)   // US Letter @ 72 dpi
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

enum RecoveryKit {
    private static let pageSize = CGSize(width: 612, height: 792)

    /// Render the kit to PDF **in memory** — no temp file is written. The only on-disk copy is the
    /// one the user later saves via `presentSavePanel`.
    @MainActor
    static func makePDF(code: String, createdAt: Date) -> Data {
        let renderer = ImageRenderer(content: RecoveryKitDocument(code: code, createdAt: createdAt))
        renderer.proposedSize = ProposedViewSize(pageSize)

        let pdfData = NSMutableData()
        var didRender = false
        renderer.render { _, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: pageSize)
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            ctx.beginPDFPage(nil)
            renderInContext(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            didRender = true
        }
        if didRender, pdfData.length > 0 { return pdfData as Data }
        return fallbackPDF(code: code, createdAt: createdAt)   // NSHostingView.dataWithPDF fallback
    }

    /// Fallback path (also fully in-memory): lay out the document in an off-screen hosting view and
    /// ask AppKit for its PDF representation.
    @MainActor
    private static func fallbackPDF(code: String, createdAt: Date) -> Data {
        let host = NSHostingView(rootView: RecoveryKitDocument(code: code, createdAt: createdAt))
        host.frame = CGRect(origin: .zero, size: pageSize)
        return host.dataWithPDF(inside: host.bounds)
    }

    /// Outcome of a save attempt, so the (mandatory) kit step only advances on a real save and can
    /// show a retryable error otherwise — first-run must never dead-end.
    enum SaveResult: Equatable { case saved, cancelled, failed(String) }

    /// Save the in-memory PDF to a user-chosen location. Writes ONLY to the path the user picks.
    @MainActor
    static func presentSavePanel(data: Data) -> SaveResult {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "surf-r Recovery Kit.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try data.write(to: url, options: .atomic)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Print the kit. Rendering stays in our view; the OS print system owns any spooling.
    @MainActor
    static func print(code: String, createdAt: Date) {
        let host = NSHostingView(rootView: RecoveryKitDocument(code: code, createdAt: createdAt))
        host.frame = CGRect(origin: .zero, size: pageSize)
        let info = NSPrintInfo.shared
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        let op = NSPrintOperation(view: host, printInfo: info)
        op.run()
    }
}
