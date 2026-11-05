import SwiftUI

/// Setup's import tour when the import never started (ImportStartGate):
/// one plain line that is also the retry.
struct ImportCouldNotStartButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(ImportStartGate.couldNotStart, systemImage: "arrow.clockwise")
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Starts the import again"))
    }
}
