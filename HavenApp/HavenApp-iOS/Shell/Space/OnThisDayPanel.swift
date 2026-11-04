import SwiftUI

/// On this day, a Your space panel (Logen, 2026-11-04; the web's
/// `desktop/space/OnThisDay.jsx`): the user's own notes from today's date one
/// and two years ago, read from their own vault (`OnThisDay`), never from a
/// relay. A row opens the note on the left, as a Live Vault row does. One
/// quiet line when there is nothing. Publishes nothing.
struct OnThisDayPanel: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @StateObject private var model = OnThisDayModel()

    private var owner: String { configService.activeAccountHexPubkey.lowercased() }
    private var relayReady: Bool { relayManager.isRunning && !relayManager.isBooting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.years == nil {
                quiet("Reading your vault...")
            } else if let years = model.years, years.contains(where: { !$0.notes.isEmpty }) {
                ForEach(years.filter { !$0.notes.isEmpty }, id: \.years) { year in
                    Text(OnThisDay.yearsText(year.years))
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    ForEach(year.notes) { note in
                        Button { model.open(note) } label: { row(note) }
                            .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 6)
            } else {
                quiet("Nothing from this day in past years.")
            }
        }
        .task(id: "\(owner)|\(relayReady)|\(model.dayKey)") {
            guard relayReady, !owner.isEmpty else { return }
            await model.load(owner: owner)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in model.checkDay() }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.appSystem(size: 13))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ note: OnThisDay.Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(OnThisDay.lineText(note.content))
                .font(.appSystem(size: 13))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Date(timeIntervalSince1970: TimeInterval(note.createdAt)), style: .time)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// The panel's notes: one vault read per year back, again when the day changes.
@MainActor
final class OnThisDayModel: ObservableObject {
    struct Year { let years: Int; let notes: [OnThisDay.Note] }

    /// nil until the first read is done.
    @Published private(set) var years: [Year]?
    @Published private(set) var dayKey = OnThisDayModel.key(Date())

    private static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    func checkDay() {
        let k = Self.key(Date())
        if k != dayKey { dayKey = k }
    }

    func load(owner: String) async {
        years = nil
        var out: [Year] = []
        for w in OnThisDay.windows() {
            let events = await VaultSocket.query(path: "", filter: OnThisDay.filter(owner: owner, w)) ?? []
            let notes = events.map {
                OnThisDay.Note(id: $0.id, pubkey: $0.pubkey, kind: $0.kind, createdAt: $0.created_at,
                               content: $0.content, tags: $0.tags)
            }
            out.append(Year(years: w.years, notes: OnThisDay.notes(notes, owner: owner, in: w)))
        }
        guard !Task.isCancelled else { return }
        years = out
    }

    /// Opens the note on the left through the path a tapped notification takes.
    func open(_ note: OnThisDay.Note) {
        NotificationOpen.pending = .note(FeedNote(id: note.id, pubkey: note.pubkey, content: note.content,
                                                  createdAt: Date(timeIntervalSince1970: TimeInterval(note.createdAt)),
                                                  tags: note.tags, kind: note.kind))
        NotificationCenter.default.post(name: .havenOpenFeed, object: nil)
        NotificationCenter.default.post(name: .havenOpenNotificationNote, object: nil)
    }
}
