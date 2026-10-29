import SwiftUI

/// A kind 33331 event's body: the object, its name and size, or the reason it
/// cannot be drawn (DECK-0003 §3.1: say why rather than failing silently).
///
/// `compact` is the quote-card size; otherwise it is the thread page, where
/// the stage takes the width and a drag turns it.
struct SnoObjectView: View {
    let note: FeedNote
    var compact = false
    var interactive = false

    var body: some View {
        switch SnoObjectCache.shared.read(note) {
        case .success(let scene):
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                SnoStageView(scene: scene, interactive: interactive)
                    .frame(maxWidth: compact ? 260 : .infinity)
                    .overlay(alignment: .topLeading) { chip(scene.object.mode) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.object.name)
                        .font(.appSystem(size: compact ? 13 : 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(detail(scene.object))
                        .font(.appSystem(size: compact ? 11 : 12, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, compact ? 0 : 4)
        case .failure(let rejection):
            refused(rejection)
        }
    }

    private func chip(_ mode: SnoObject.Mode) -> some View {
        Text(String(localized: "sno.chip", defaultValue: "3D object"))
            .font(.appSystem(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .padding(8)
            .accessibilityHidden(true)
    }

    private func detail(_ object: SnoObject) -> String {
        let counts = String(localized: "sno.counts",
                            defaultValue: "\(object.positions.count) vertices · \(object.faces.count) faces")
        guard interactive else { return counts }
        return counts + " · " + String(localized: "sno.dragHint", defaultValue: "Drag to turn")
    }

    private func refused(_ rejection: SnoObject.Rejection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let alt = note.tags.first(where: { $0.first == "alt" && $0.count > 1 })?[1], !alt.isEmpty {
                Text(alt)
                    .font(.appSystem(size: compact ? 13 : 15, weight: .regular))
                    .foregroundColor(.primary.opacity(0.9))
            }
            Text(String(localized: "sno.refused",
                        defaultValue: "This 3D object can't be shown: \(rejection.reason)."))
                .font(.appSystem(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

/// Each object is read and validated once per event, not on every redraw of
/// the row that shows it. Keyed by event id, which changes with every edit of
/// an addressable object.
@MainActor
final class SnoObjectCache {
    static let shared = SnoObjectCache()
    private var entries: [String: Result<SnoScene, SnoObject.Rejection>] = [:]

    func read(_ note: FeedNote) -> Result<SnoScene, SnoObject.Rejection> {
        if let hit = entries[note.id] { return hit }
        let result = SnoObject.read(note.content).map(SnoScene.init)
        if entries.count > 200 { entries.removeAll() }
        entries[note.id] = result
        return result
    }
}
