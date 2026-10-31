import SwiftUI

/// One row of Settings > Relays (option A): Remove or Undo, the relay's name
/// and speed with a YOURS or DEFAULT tag, then the five job dots. A removed
/// row stays in place, struck through, until Save. Twin of Android
/// `RelayMatrixScreen.kt`'s DraftRow.
struct RelayDraftRowView: View {
    let row: RelayDraft.Row
    let result: RelayProbe.Result?
    let open: () -> Void
    let toggle: (RelayMatrix.Job) -> Void
    let remove: () -> Void
    let undo: () -> Void

    static let dotWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: row.removed ? undo : remove) {
                Image(systemName: row.removed ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill")
                    .font(.title3)
                    .foregroundColor(row.removed ? .havenPurple : .red)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.removed ? "Undo remove \(RelayMatrix.label(row.url))" : "Remove \(RelayMatrix.label(row.url))")
            VStack(alignment: .leading, spacing: 0) {
                Button(action: open) {
                    Text(RelayMatrix.label(row.url))
                        .font(.appBody)
                        .strikethrough(row.removed)
                        .foregroundColor(row.removed ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.removed)
                .accessibilityHint("Shows every job for this relay")
                HStack(spacing: 6) {
                    Circle().fill(RelayMatrixView.healthColor(result)).frame(width: 8, height: 8)
                    if !row.removed { speed }
                    if row.entry.section == .yours {
                        RelayTag(text: "YOURS", tint: .havenPurple)
                    } else {
                        RelayTag(text: "DEFAULT", tint: .secondary)
                    }
                    if row.removed { RelayTag(text: "REMOVED", tint: .red) }
                    Spacer(minLength: 2)
                    HStack(spacing: 0) {
                        ForEach(RelayMatrix.Job.allCases) { dot($0) }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var speed: some View {
        let text: String
        var tint = Color.secondary
        switch result {
        case .answered(let ms):
            text = "\(ms) ms"
            if ms > RelayProbe.slowMilliseconds { tint = .orange }
        case .unreachable:
            text = "down"
            tint = .red
        case .probing, .none:
            text = "…"
        }
        return Text(text).font(.appCaption).foregroundColor(tint).lineLimit(1).fixedSize()
    }

    private func dot(_ job: RelayMatrix.Job) -> some View {
        let on = !row.removed && row.has(job)
        return Button { toggle(job) } label: {
            RelayJobDot(on: on)
        }
        .buttonStyle(.plain)
        .disabled(row.removed)
        .accessibilityLabel("\(job.title), \(RelayMatrix.label(row.url))")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// A job dot: filled when the relay does that job.
struct RelayJobDot: View {
    let on: Bool
    var locked = false

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? Color.havenPurple : Color.clear)
                .overlay(Circle().stroke(on ? Color.havenPurple : Color.secondary.opacity(0.5), lineWidth: 1.5))
            if locked && on {
                Image(systemName: "lock.fill")
                    .font(.appSystem(size: 8, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: RelayDraftRowView.dotWidth, height: 30)
        .contentShape(Rectangle())
    }
}

/// The small capital tag under a relay's name.
struct RelayTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.appSystem(size: 9, weight: .bold))
            .foregroundColor(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.15)))
            .fixedSize()
    }
}

/// Section header: the title, then the five job names over the dot columns.
struct RelayJobHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.appCaption.weight(.semibold))
                .textCase(nil)
            HStack(spacing: 0) {
                Text("Relay")
                Spacer()
                ForEach(RelayMatrix.Job.allCases) { job in
                    Text(job.title)
                        .font(.appSystem(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: RelayDraftRowView.dotWidth)
                }
            }
        }
    }
}
