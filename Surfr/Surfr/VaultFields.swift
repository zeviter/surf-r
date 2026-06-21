import SwiftUI
import AppKit

/// A visibly outlined checkbox toggle style. The default macOS `Toggle` can render switch-like or with
/// a near-invisible box in some overlay layouts; this guarantees an outlined box at rest and a filled
/// check when on — for the mandatory "I've saved my kit" consent and the enable toggles.
struct OutlinedCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Color.accentColor : Color.clear)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(configuration.isOn ? Color.accentColor : Color.secondary, lineWidth: 1.5)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A password field that (a) grabs first-responder focus on present — so keystrokes never leak to the
/// page/omnibox behind an overlay — and (b) has a reveal (eye) toggle to catch typos. The shared
/// credential-field primitive for the vault (master entry now, item fields in Slice 5).
struct VaultPasswordField: View {
    let placeholder: String
    @Binding var text: String
    var autoFocus = false
    var onSubmit: () -> Void = {}

    @State private var reveal = false

    var body: some View {
        HStack(spacing: 6) {
            VaultTextFieldRep(text: $text, placeholder: placeholder, secure: !reveal,
                              autoFocus: autoFocus, onSubmit: onSubmit)
                .id(reveal)   // recreate on toggle so the right NSTextField subclass is used (and refocuses)
            Button { reveal.toggle() } label: {
                Image(systemName: reveal ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.secondary).frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(reveal ? "Hide" : "Show")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
    }
}

/// A non-secret text field with the same focus-grab + smart-substitution-off behaviour — for the
/// recovery-code entry, which must never be mangled by smart dashes / autocorrect.
struct VaultPlainField: View {
    let placeholder: String
    @Binding var text: String
    var autoFocus = false
    var onSubmit: () -> Void = {}

    var body: some View {
        VaultTextFieldRep(text: $text, placeholder: placeholder, secure: false,
                          autoFocus: autoFocus, onSubmit: onSubmit)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.35)))
    }
}

/// NSTextField-backed field with reliable first-responder focus (retry until the window is key, like
/// the Spotlight omnibox) and smart dash/quote/replacement/spelling substitutions disabled (so a
/// recovery code or password is never silently altered).
struct VaultTextFieldRep: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let secure: Bool
    var autoFocus: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = text
        if autoFocus { context.coordinator.beginFocus(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: VaultTextFieldRep
        init(_ parent: VaultTextFieldRep) { self.parent = parent }

        func beginFocus(_ field: NSTextField) { focus(field, attempt: 0) }

        private func focus(_ field: NSTextField, attempt: Int) {
            if let window = field.window, window.makeFirstResponder(field), field.currentEditor() != nil {
                disableSubstitutions(field)
                return
            }
            guard attempt < 30 else { return }
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                self.focus(field, attempt: attempt + 1)
            }
        }

        private func disableSubstitutions(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField { disableSubstitutions(field) }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}
