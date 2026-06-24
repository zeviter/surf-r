import SwiftUI
import AppKit

/// Catches the **Escape** key for whatever surface it's embedded in, **regardless of which control is
/// first responder**. It overrides `performKeyEquivalent`, which the window dispatches down the whole
/// view tree for every key event — so unlike `.onExitCommand` / `.onKeyPress` (which need the view or a
/// descendant focused), this fires for the vault list / item detail / Security Check even when nothing
/// inside them holds focus.
///
/// Sheets present in their own child window, so their Escape is unaffected (this view isn't in the
/// sheet's tree). The vault editor's Cancel button keeps its own `.cancelAction`; whichever consumes
/// Escape first wins, and both do the same single "pop one level", so there's no double-handling.
struct EscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onEscape: onEscape) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onEscape = onEscape
    }

    private final class CatcherView: NSView {
        var onEscape: () -> Void
        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 53 {            // 53 = Escape
                onEscape()
                return true                      // consumed
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
