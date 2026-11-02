import SwiftUI

/// The Mac dashboard's way in to List backups. The Mac relay dashboard
/// isn't inside a navigation stack, so the page opens as a sheet with its
/// own. iPhone reaches the same page from the Vault Dashboard and Settings.
struct DashboardListBackupsRow: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                RowIcon(icon: "clock.arrow.circlepath", state: .info)
                RowText(title: "List backups",
                        detail: "Your vault keeps old versions of every list and your profile.")
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showing) {
            NavigationStack {
                ListBackupView()
                    .navigationTitle("List backups")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showing = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 600, minHeight: 460, idealHeight: 560)
            #endif
        }
    }
}
