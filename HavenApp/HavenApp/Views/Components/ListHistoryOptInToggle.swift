import SwiftUI

/// Moving in's choice to also look for older versions of the owner's lists on
/// history relays (ListHistoryScan). Off by default; the caller passes the
/// value to `RelayProcessManager.importNotes(listHistory:)`.
struct ListHistoryOptInToggle: View {
    @Binding var isOn: Bool
    var textColor: Color = .secondary

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(ListHistoryScan.optInLabel)
                .font(.appSystem(size: 13))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .accessibilityIdentifier("import.listHistory.optIn")
    }
}
