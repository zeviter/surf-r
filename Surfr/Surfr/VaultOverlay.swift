import SwiftUI
import AppKit

/// The vault gate overlay (WF-2 first-run / WF-3 unlock), presented over a dimmed page exactly like
/// the Spotlight omnibox. Routes on `gate.phase`. The unlock screen is dismissable (click-away/Esc);
/// first-run is not — you either finish (mandatory kit) or explicitly cancel (which discards).
struct VaultOverlay: View {
    @ObservedObject var gate: VaultGate
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { if gate.phase == .locked { onClose() } }   // unlock dismisses; first-run doesn't

            card
                .frame(width: 440)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25)))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        }
    }

    @ViewBuilder private var card: some View {
        switch gate.phase {
        case .firstRun, .uninitialized:
            switch gate.firstRunStep {
            case .setMaster:   FirstRunMasterView(gate: gate, onCancel: cancelFirstRun)
            case .recoveryKit: RecoveryKitStepView(gate: gate, onCancel: cancelFirstRun)
            case .committed:   ProgressView().padding(40)
            }
        case .locked:
            UnlockView(gate: gate, onClose: onClose)
        case .unlocked:
            Color.clear.frame(height: 0).onAppear { onClose() }
        }
    }

    private func cancelFirstRun() {
        gate.abandonFirstRun()
        onClose()
    }
}

// MARK: - First run · set master (WF-2 step 1)

private struct FirstRunMasterView: View {
    @ObservedObject var gate: VaultGate
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirm = ""

    private var strength: PasswordStrength { PasswordStrengthEstimator.estimate(password) }
    private var mismatch: Bool { !confirm.isEmpty && confirm != password }
    private var canContinue: Bool { !password.isEmpty && password == confirm && !gate.isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultHeader(title: "Create your vault",
                        subtitle: "Your master password is the root of trust. Pick a passphrase of 6+ words — long is stronger than complicated.")

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
            if !password.isEmpty { PasswordStrengthMeter(strength: strength) }

            SecureField("Confirm master password", text: $confirm)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canContinue { Task { await gate.submitMaster(password) } } }
            if mismatch {
                Text("Passwords don't match.").font(.caption).foregroundStyle(.red)
            }

            if let error = gate.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                if gate.isWorking { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Continue") { Task { await gate.submitMaster(password) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding(.top, 4)
        }
        .padding(22)
    }
}

// MARK: - First run · Recovery Kit (WF-2 step 2 / WF-10)

private struct RecoveryKitStepView: View {
    @ObservedObject var gate: VaultGate
    let onCancel: () -> Void

    @State private var savedOrPrinted = false
    @State private var acknowledged = false
    @State private var enableBiometric = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultHeader(title: "Save your Recovery Kit",
                        subtitle: "This is the only way back into your vault if you forget your master password. Save or print it, then store it offline.")

            VStack(alignment: .leading, spacing: 6) {
                Text("RECOVERY CODE").font(.caption).bold().foregroundStyle(.secondary)
                Text(gate.recoveryCodeForDisplay)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
            }

            Text("There is no backstop. Anyone with this code and your device can open your vault. Lose both your master password and this kit and the vault is unrecoverable — by design.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button {
                    let data = RecoveryKit.makePDF(code: gate.recoveryCodeForDisplay, createdAt: Date())
                    RecoveryKit.presentSavePanel(data: data)
                    savedOrPrinted = true
                } label: { Label("Save PDF…", systemImage: "square.and.arrow.down") }
                Button {
                    RecoveryKit.print(code: gate.recoveryCodeForDisplay, createdAt: Date())
                    savedOrPrinted = true
                } label: { Label("Print…", systemImage: "printer") }
            }

            Toggle("I've saved my Recovery Kit somewhere safe", isOn: $acknowledged)
                .disabled(!savedOrPrinted)
                .font(.callout)
            if !savedOrPrinted {
                Text("Save or print the kit to continue.").font(.caption).foregroundStyle(.tertiary)
            }

            if gate.biometricAvailable {
                Toggle("Enable Touch ID for faster unlock", isOn: $enableBiometric)
                    .font(.callout)
            }

            if let error = gate.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                if gate.isWorking { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Finish") { Task { await gate.acknowledgeKit(enableBiometric: enableBiometric) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!acknowledged || gate.isWorking)
            }
            .padding(.top, 4)
        }
        .padding(22)
    }
}

// MARK: - Unlock (WF-3)

private struct UnlockView: View {
    @ObservedObject var gate: VaultGate
    let onClose: () -> Void

    @State private var password = ""
    @State private var showRecovery = false
    @State private var biometricTried = false

    var body: some View {
        if showRecovery {
            RecoveryResetView(gate: gate, onClose: onClose, onBack: { showRecovery = false })
        } else {
            VStack(alignment: .leading, spacing: 14) {
                VaultHeader(title: "Unlock vault", subtitle: nil)

                SecureField("Master password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { attempt() }

                if gate.shouldOfferBiometric {
                    Button { tryBiometric() } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.bordered)
                }

                if let error = gate.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                HStack {
                    Button("Use recovery code") { gate.clearError(); showRecovery = true }
                        .buttonStyle(.link)
                    Spacer()
                    if gate.isWorking { ProgressView().controlSize(.small).padding(.trailing, 6) }
                    Button("Unlock", action: attempt)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || gate.isWorking)
                }
                .padding(.top, 4)
            }
            .padding(22)
            // Biometric fires automatically on present (WF-3 / §4), once; master is always the fallback.
            .task {
                guard !biometricTried else { return }
                biometricTried = true
                tryBiometric()
            }
        }
    }

    private func tryBiometric() {
        guard gate.shouldOfferBiometric else { return }
        Task { if await gate.unlockWithBiometric() { onClose() } }
    }

    private func attempt() {
        guard !password.isEmpty else { return }
        Task { if await gate.unlock(master: password) { onClose() } }
    }
}

private struct RecoveryResetView: View {
    @ObservedObject var gate: VaultGate
    let onClose: () -> Void
    let onBack: () -> Void

    @State private var code = ""
    @State private var newMaster = ""
    @State private var confirm = ""

    private var strength: PasswordStrength { PasswordStrengthEstimator.estimate(newMaster) }
    private var canReset: Bool { !code.isEmpty && !newMaster.isEmpty && newMaster == confirm && !gate.isWorking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VaultHeader(title: "Reset master password",
                        subtitle: "Enter your recovery code, then choose a new master password.")

            TextField("Recovery code", text: $code).textFieldStyle(.roundedBorder)
            SecureField("New master password", text: $newMaster).textFieldStyle(.roundedBorder)
            if !newMaster.isEmpty { PasswordStrengthMeter(strength: strength) }
            SecureField("Confirm new master password", text: $confirm).textFieldStyle(.roundedBorder)

            if let error = gate.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Back") { gate.clearError(); onBack() }
                Spacer()
                if gate.isWorking { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Reset & Unlock") {
                    Task { if await gate.resetWithRecovery(code: code, newMaster: newMaster) { onClose() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canReset)
            }
            .padding(.top, 4)
        }
        .padding(22)
    }
}

// MARK: - Shared bits

private struct VaultHeader: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                Text(title).font(.title3).bold()
            }
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Vault surface placeholder (Slice 3 stub; list/detail arrive in Slice 5)

/// The full-page vault surface shown once unlocked. Slice 3 ships a placeholder so the flow is
/// verifiable end-to-end; Slice 5 replaces it with the `PageScaffold` list/detail/add-edit.
struct VaultSurfacePlaceholder: View {
    @EnvironmentObject private var gate: VaultGate

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Vault unlocked").font(.title2).bold()
            Text("Your saved logins will appear here. The list, detail, and add/edit views arrive in the next slice.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)

            // Biometric: re-enable after an enrolment-change invalidation, or enable if not yet on.
            if gate.biometricAvailable {
                if gate.needsBiometricReenroll {
                    Button { gate.enableBiometric() } label: { Label("Re-enable Touch ID", systemImage: "touchid") }
                        .help("Touch ID was reset when your enrolment changed. Re-enable it for this device.")
                } else if !gate.biometricEnabled {
                    Button { gate.enableBiometric() } label: { Label("Enable Touch ID", systemImage: "touchid") }
                } else {
                    Button(role: .destructive) { gate.disableBiometric() } label: { Label("Disable Touch ID", systemImage: "touchid") }
                }
            }

            Button { gate.lockNow() } label: { Label("Lock vault", systemImage: "lock") }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct PasswordStrengthMeter: View {
    let strength: PasswordStrength

    private var color: Color {
        switch strength.level {
        case .veryWeak: return .red
        case .weak:     return .orange
        case .fair:     return .yellow
        case .good:     return .green
        case .strong:   return .green
        }
    }
    private var fillFraction: Double { Double(strength.level.rawValue + 1) / 5.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule().fill(color).frame(width: geo.size.width * fillFraction)
                }
            }
            .frame(height: 6)
            HStack {
                Text(strength.level.label).font(.caption).foregroundStyle(color)
                Spacer()
                Text("≈\(Int(strength.estimatedBits)) bits").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(strength.hint).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
