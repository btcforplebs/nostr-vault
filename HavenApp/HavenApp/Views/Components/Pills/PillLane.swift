import SwiftUI

/// How important a pill is. The lane shows the most important first; see
/// `docs/pills.md`.
enum PillLevel: Int, Comparable {
    /// Something failed.
    case error = 1
    /// Something you did finished, or something arrived for you.
    case result
    /// What a button you just tapped did. A new one replaces the old one.
    case feedback
    /// Background info (New Posts, a rebuild, an import). Shows only while
    /// nothing above it does.
    case ambient

    static func < (a: PillLevel, b: PillLevel) -> Bool { a.rawValue < b.rawValue }
}

/// The one lane every pill draws in, top-centre under the navigation bar.
/// Each pill registers while its manager shows it (`PillSlot`); the lane
/// decides which may draw: the two most important, newest first within a
/// level, with only the newest feedback pill, and ambient pills only when
/// nothing else is up.
@MainActor
final class PillLane: ObservableObject {
    static let shared = PillLane()
    /// At most this many pills draw at once.
    static let maxVisible = 2

    private struct Entry {
        let level: PillLevel
        let since: Date
    }

    private var entries: [String: Entry] = [:]
    /// The ids that may draw now.
    @Published private(set) var visible: Set<String> = []
    /// True while any error, result or feedback pill is drawn. Pills that a
    /// screen draws itself (the Feed's New Posts, the WoT rebuild pill) are
    /// ambient: hide them while this is true.
    @Published private(set) var hidesAmbient = false

    func enter(_ id: String, _ level: PillLevel) {
        if level == .feedback {
            // Feedback never stacks: the newest replaces the rest.
            entries = entries.filter { $0.value.level != .feedback }
        }
        entries[id] = Entry(level: level, since: Date())
        recompute()
    }

    func leave(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    private func recompute() {
        let ranked = entries
            .filter { $0.value.level != .ambient }
            .sorted { a, b in
                a.value.level != b.value.level ? a.value.level < b.value.level : a.value.since > b.value.since
            }
            .prefix(Self.maxVisible)
            .map(\.key)
        var next = Set(ranked)
        if next.isEmpty, let ambient = entries
            .filter({ $0.value.level == .ambient })
            .max(by: { $0.value.since < $1.value.since })?.key {
            next.insert(ambient)
        }
        let hides = next.contains { entries[$0]?.level != .ambient }
        if next != visible { visible = next }
        if hides != hidesAmbient { hidesAmbient = hides }
    }
}

/// One pill in the lane: registers `id` at `level` for as long as the slot
/// is in the hierarchy, and draws `content` only while the lane lets it.
/// Takes no room when held back, so a lane stack is `VStack(spacing: 0)`
/// and each drawn pill brings its own gap.
struct PillSlot<Content: View>: View {
    let id: String
    let level: PillLevel
    @ViewBuilder let content: () -> Content
    @ObservedObject private var lane = PillLane.shared

    init(_ id: String, level: PillLevel, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.level = level
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            // Always present, so appear/disappear track the manager, not the lane.
            Color.clear.frame(height: 0)
            if lane.visible.contains(id) {
                content()
                    .padding(.top, PillStyle.gap)
                    .transition(Motion.pillTransition)
            }
        }
        .animation(Motion.bannerIn, value: lane.visible.contains(id))
        .onAppear { lane.enter(id, level) }
        .onDisappear { lane.leave(id) }
    }
}
