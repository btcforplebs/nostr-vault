import SwiftUI

/// On the vault dashboard: a list another app just clobbered (wiped, swapped
/// for other entries, or drained in steps), from the vault's history and
/// ListWipeAlarmRule. "Your follows went from 412 to 3 on 4 Nov, changed by
/// Amethyst." Recover asks first (ListRestoreView), Merge opens List
/// backups › Merge for the kinds it can merge, "Keep the new list" hides it
/// for good. Nothing is ever restored or published on its own.
struct ListWipeBanner: View {
    @ObservedObject private var service = ListBackupService.shared
    @ObservedObject private var config = ConfigService.shared
    @State private var restoring: ListVersion?
    @State private var merging: MergeTarget?

    private struct MergeTarget: Identifiable {
        let key: ListHistory.Key
        var id: String { "\(key.kind):\(key.d)" }
    }

    var body: some View {
        let alarms = service.alarms
        VStack(spacing: 12) {
            ForEach(alarms.prefix(3), id: \.alarm.after.id) { item in
                card(item.key, item.alarm)
            }
        }
        // Stays in the dashboard's stack while empty, so the load and the
        // sheets outlive the card; the negative padding takes back the
        // stack's spacing then.
        .padding(.bottom, alarms.isEmpty ? -24 : 0)
        .task(id: config.config.activeAccountNpub) { await service.load() }
        .sheet(item: $restoring) { old in ListRestoreView(old: old) }
        .sheet(item: $merging) { target in
            ListMergeView(key: target.key)
        }
    }

    private func card(_ key: ListHistory.Key, _ alarm: ListWipeAlarmRule.Alarm) -> some View {
        let day = Date(timeIntervalSince1970: TimeInterval(alarm.after.createdAt)).formatted(.dateTime.day().month())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.appSystem(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text(ListWipeAlarmWording.headline(alarm, key: key, day: day))
                        .font(.appSystem(size: 15, weight: .semibold))
                    Text("Your vault kept the list from before. Recover it, or merge it with the new one. If you made this change yourself, keep the new list.")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Recover") { restoring = alarm.before }
                    .buttonStyle(.borderedProminent)
                if ListVersionMerge.canMerge(key.kind) {
                    Button("Merge") { merging = MergeTarget(key: key) }
                        .buttonStyle(.bordered)
                }
                Button("Keep the new list") { service.dismiss(afterID: alarm.after.id) }
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
