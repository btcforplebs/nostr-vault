import SwiftUI

/// Notes / My notes above the Vault's search results (`VaultSearchScope`).
/// Two segments, the width of the content column on a phone and no wider
/// than reads well on an iPad or Mac.
struct VaultSearchScopePicker: View {
    let scope: VaultSearchScope
    let onScope: (VaultSearchScope) -> Void

    var body: some View {
        Picker("Search in", selection: Binding(get: { scope }, set: onScope)) {
            ForEach(VaultSearchScope.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
        .padding(.horizontal, 16)
        .accessibilityLabel("Search in")
        .accessibilityHint("My notes shows only what you wrote")
    }
}
