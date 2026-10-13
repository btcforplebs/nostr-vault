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
        /// How many hosts draw this pill (the Mac's main window and an open
        /// sheet both do); it leaves the lane when the last one goes.
        var hosts: Int
    }

    private var entries: [String: Entry] = [:]
    /// The ids that may draw now.
    @Published private(set) var visible: Set<String> = []
    /// True while any error, result or feedback pill is drawn. Pills that a
    /// screen draws itself (the Feed's New Posts, the WoT rebuild pill) are
    /// ambient: hide them while this is true.
    @Published private(set) var hidesAmbient = false

    func enter(_ id: String, _ level: PillLevel) {
        if var entry = entries[id] {
            // Another host of the same pill.
            entry.hosts += 1
            entries[id] = entry
        } else {
            if level == .feedback {
                // Feedback never stacks: the newest replaces the rest.
                entries = entries.filter { $0.value.level != .feedback }
            }
            entries[id] = Entry(level: level, since: Date(), hosts: 1)
        }
        recompute()
    }

    /// The pill changed level (a send that failed), keeping its place in time.
    func relevel(_ id: String, _ level: PillLevel) {
        guard let entry = entries[id], entry.level != level else { return }
        entries[id] = Entry(level: level, since: entry.since, hosts: entry.hosts)
        recompute()
    }

    func leave(_ id: String) {
        guard var entry = entries[id] else { return }
        entry.hosts -= 1
        entries[id] = entry.hosts > 0 ? entry : nil
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
        // A sending pill that fails moves up to an error.
        .onChange(of: level) { _, new in lane.relevel(id, new) }
    }
}

/// A pill a screen draws itself (the Feed's New Posts, the WoT rebuild
/// pill): level 4, ambient. It fades out while the lane shows anything
/// above it and comes back after, keeping its place so nothing jumps.
struct AmbientPill: ViewModifier {
    @ObservedObject private var lane = PillLane.shared

    func body(content: Content) -> some View {
        content
            .opacity(lane.hidesAmbient ? 0 : 1)
            .allowsHitTesting(!lane.hidesAmbient)
            .accessibilityHidden(lane.hidesAmbient)
            .animation(Motion.fade, value: lane.hidesAmbient)
    }
}

extension View {
    /// Makes this an ambient pill; see `AmbientPill`.
    func ambientPill() -> some View { modifier(AmbientPill()) }
}
