import SwiftUI

/// On the vault dashboard: a list that just lost most of what it held, from
/// the vault's history. "Your bookmarks went from 240 to 0 on 2 Nov." Restore
/// asks first (ListRestoreView); "Keep the new list" hides it for good.
/// Nothing is ever restored on its own.
struct ListWipeBanner: View {
    @ObservedObject private var service = ListBackupService.shared
    @ObservedObject private var config = ConfigService.shared
    @State private var restoring: ListVersion?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(service.wipes.prefix(3), id: \.wipe.after.id) { item in
                card(item.key, item.wipe)
            }
        }
        // Stays in the dashboard's stack while empty, so the load and the
        // restore sheet outlive the card; the negative padding takes back
        // the stack's spacing then.
        .padding(.bottom, service.wipes.isEmpty ? -24 : 0)
        .task(id: config.config.activeAccountNpub) { await service.load() }
        .sheet(item: $restoring) { old in ListRestoreView(old: old) }
    }

    private func card(_ key: ListHistory.Key, _ wipe: ListHistory.Wipe) -> some View {
        let name = ListBackupFormat.title(key)
        let from = ListShrinkRule.itemCount(wipe.before), to = ListShrinkRule.itemCount(wipe.after)
        let day = Date(timeIntervalSince1970: TimeInterval(wipe.after.createdAt)).formatted(.dateTime.day().month())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.appSystem(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your \(name.lowercased()) went from \(from) to \(to) on \(day).")
                        .font(.appSystem(size: 15, weight: .semibold))
                    Text("Your vault kept the list from before. Restore it?")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Restore") { restoring = wipe.before }
                    .buttonStyle(.borderedProminent)
                Button("Keep the new list") { service.dismiss(wipe) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
