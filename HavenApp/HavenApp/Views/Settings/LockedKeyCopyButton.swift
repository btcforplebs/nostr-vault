import SwiftUI

/// Reveal Private Key's second copy: the key locked with a password (NIP-49
/// ncryptsec), the safe one to take to another app (NDK check step 4, Logen
/// 2026-11-04). `kept`: the ncryptsec this device keeps, copied as it is (it
/// opens with the password just typed). Without one (an old plaintext key),
/// the user chooses a new password, typed twice, before anything is locked
/// (Tron, PR 1658). Twin of Android `LockedKeyCopyButton.kt`.
struct LockedKeyCopyButton: View {
    let kept: String?
    let nsec: String
    @State private var copied = false
    @State private var choosing = false
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if choosing {
                newPasswordFields
            } else {
                Button {
                    if let kept { copy(kept) } else { choosing = true }
                } label: {
                    Label(copied ? "Copied!" : "Copy locked key (ncryptsec)",
                          systemImage: copied ? "checkmark" : "lock.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("revealKey.copyLocked")
                Text(kept != nil ? LockedKeyExport.caption : LockedKeyExport.newPasswordCaption)
                    .font(.appCaption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.appCaption).foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var newPasswordFields: some View {
        let problem = LockedKeyExport.passwordProblem(newPassword, confirm)
        Text(LockedKeyExport.newPasswordCaption)
            .font(.appCaption2)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        SecureField("New password (8 or more)", text: $newPassword)
            .textContentType(.newPassword)
        SecureField("The same again", text: $confirm)
            .textContentType(.newPassword)
        if !problem.isEmpty && !confirm.isEmpty {
            Text(problem).font(.appCaption).foregroundColor(.red)
        }
        HStack {
            Button("Cancel") { reset() }
            Spacer()
            Button("Lock and copy") {
                do {
                    let locked = try NIP49Service.encrypt(nsec: nsec, password: newPassword)
                    guard LockedKeyExport.kept(locked) != nil else { throw CocoaError(.coderInvalidValue) }
                    reset()
                    copy(locked)
                } catch {
                    self.error = "Couldn't lock the key. Nothing was copied."
                }
            }
            .disabled(!problem.isEmpty)
            .buttonStyle(.borderedProminent)
        }
    }

    private func reset() {
        choosing = false
        newPassword = ""
        confirm = ""
        error = nil
    }

    private func copy(_ ncryptsec: String) {
        PlatformClipboard.copy(ncryptsec)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { copied = false }
        }
    }
}
