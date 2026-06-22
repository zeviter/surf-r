import SwiftUI
import SurfrCore

/// Inline password/passphrase generator (WF-6). Pure logic lives in `SurfrCore.PasswordGenerator`;
/// this is just the controls + a live preview/entropy badge. "Use password" hands the value back.
struct GeneratorView: View {
    /// Called with the chosen value; the host writes it into the password field and dismisses.
    let onUse: (String) -> Void

    private enum Mode: String, CaseIterable { case random = "Random", passphrase = "Passphrase" }
    @State private var mode: Mode = .random
    @State private var random = PasswordGenerator.RandomOptions()
    @State private var passphrase = PasswordGenerator.PassphraseOptions()
    @State private var preview = ""
    @State private var classWarning: String?

    private let separators: [(label: String, value: String)] = [("hyphen", "-"), ("period", "."), ("underscore", "_"), ("space", " ")]

    private var bits: Double {
        mode == .random ? PasswordGenerator.entropyBits(for: random)
                        : PasswordGenerator.passphraseEntropyBits(wordCount: passphrase.wordCount)
    }
    private var strength: PasswordGenerator.Strength { PasswordGenerator.strength(bits: bits) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            previewBox

            if mode == .random { randomControls } else { passphraseControls }

            Button { onUse(preview) } label: { Text("Use password").frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.isEmpty)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: regenerate)
        .onChange(of: mode) { _, _ in regenerate() }
        .onChange(of: random) { _, _ in regenerate() }
        .onChange(of: passphrase) { _, _ in regenerate() }
    }

    private var previewBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(preview).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(spacing: 6) {
                    Button { regenerate() } label: { Image(systemName: "arrow.clockwise") }.help("Regenerate")
                    Button { VaultClipboard.copyConcealed(preview) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                }.buttonStyle(.plain)
            }
            // Entropy + strength
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2))
                        Capsule().fill(strengthColor).frame(width: geo.size.width * min(bits / 128, 1))
                    }
                }.frame(height: 6)
                Text("≈ \(Int(bits)) bits · \(strength.rawValue)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    private var strengthColor: Color {
        switch strength { case .weak: return .red; case .fair: return .orange; case .strong: return .green; case .excellent: return .green }
    }

    @ViewBuilder private var randomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Length").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(random.length) }, set: { random.length = Int($0) }), in: 8...64, step: 1)
                Text("\(random.length)").font(.system(.caption, design: .monospaced)).frame(width: 24)
            }
            HStack(spacing: 12) {
                classToggle("A–Z", \.upper)
                classToggle("a–z", \.lower)
                classToggle("0–9", \.digits)
                classToggle("!@#", \.symbols)
            }
            if let classWarning { Text(classWarning).font(.caption).foregroundStyle(.orange) }
            Toggle("Exclude ambiguous (0 O o l I 1 |)", isOn: $random.excludeAmbiguous).font(.caption)
        }
    }

    /// Toggle that refuses to disable the LAST enabled class — visibly, not by silently flipping
    /// another toggle back on.
    private func classToggle(_ label: String, _ keyPath: WritableKeyPath<PasswordGenerator.RandomOptions, Bool>) -> some View {
        let isOn = Binding<Bool>(
            get: { random[keyPath: keyPath] },
            set: { newValue in
                if newValue == false {
                    let enabled = [random.upper, random.lower, random.digits, random.symbols].filter { $0 }.count
                    if enabled <= 1 { classWarning = "Keep at least one character type."; return }
                }
                random[keyPath: keyPath] = newValue
                classWarning = nil
            }
        )
        return Toggle(label, isOn: isOn).toggleStyle(.button).font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder private var passphraseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Words: \(passphrase.wordCount)", value: $passphrase.wordCount, in: 4...10).font(.caption)
            if passphrase.wordCount < 6 {
                Text("6+ words (~77 bits) recommended for a master password.").font(.caption).foregroundStyle(.orange)
            }
            Picker("Separator", selection: $passphrase.separator) {
                ForEach(separators, id: \.value) { Text($0.label).tag($0.value) }
            }.font(.caption)
            Picker("Capitalization", selection: $passphrase.caps) {
                Text("none").tag(PasswordGenerator.PassphraseOptions.Caps.none)
                Text("Title Case").tag(PasswordGenerator.PassphraseOptions.Caps.title)
                Text("Random word").tag(PasswordGenerator.PassphraseOptions.Caps.randomWord)
            }.font(.caption)
        }
    }

    private func regenerate() {
        preview = mode == .random ? PasswordGenerator.random(random) : PasswordGenerator.passphrase(passphrase)
    }
}
