import SwiftUI

/// Moving in's choice to also look for older versions of the owner's lists on
/// history relays (ListHistoryScan). On by default (ListHistoryScan.defaultOn);
/// the caller passes the value to `RelayProcessManager.importNotes(listHistory:)`.
struct ListHistoryOptInToggle: View {
    @Binding var isOn: Bool
    var textColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(ListHistoryScan.optInLabel)
                    .font(.appSystem(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .accessibilityIdentifier("import.listHistory.optIn")

            // Outside the Toggle's label so tapping the link opens the browser
            // instead of flipping the switch.
            detail
                .font(.appSystem(size: 12))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .padding(.leading, 20)
                #endif
                .accessibilityIdentifier("import.listHistory.detail")
        }
    }

    private var detail: Text {
        var link = AttributedString(ListHistoryScan.optInDetailLink)
        link.link = ListHistoryScan.lazarusURL
        link.underlineStyle = .single
        return Text(ListHistoryScan.optInDetailBefore) + Text(link) + Text(ListHistoryScan.optInDetailAfter)
    }
}
