import SwiftUI

// MARK: - Post Action Notification Banner

struct PostActionNotificationBanner: View {
    @ObservedObject private var manager = PendingPostManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if manager.isShowing, let actionType = manager.actionType {
                PillSlot("postAction", level: .result) {
                PostActionPill(
                    actionType: actionType,
                    timeRemaining: manager.timeRemaining,
                    totalTime: manager.totalTime,
                    onUndo: { manager.cancel() },
                    onEdit: actionType.canEdit ? { manager.requestEdit() } : nil,
                    onDismiss: { manager.dismissBanner() }
                )
                }
            } else if let confirmation = manager.confirmation {
                PillSlot("postConfirmation-\(confirmation.id)", level: .result) {
                    PostConfirmationPill(confirmation: confirmation)
                }
            }
        }
    }
}

// MARK: - Post Confirmation Pill

/// After the countdown: "Reposting…" until a relay takes it, then a green
/// "Reposted". If no relay confirms after the retries, a grey note instead of
/// a red error.
struct PostConfirmationPill: View {
    let confirmation: PendingPostManager.Confirmation

    var body: some View {
        HStack(spacing: 6) {
            if confirmation.state == .sending {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: confirmation.state == .confirmed ? "checkmark" : "clock")
                    .font(PillSize.regular.iconFont)
            }
            Text(label)
                .lineLimit(1)
        }
        .pillCapsule(tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch confirmation.state {
        case .sending:     return "\(confirmation.actionType.label)…"
        case .confirmed:   return confirmation.actionType.doneLabel
        case .unconfirmed: return "Sent. No relay has confirmed it yet"
        }
    }

    private var tone: PillTone {
        switch confirmation.state {
        case .sending:     return .accent
        case .confirmed:   return .success
        case .unconfirmed: return .neutral
        }
    }
}

// MARK: - Post Action Pill

struct PostActionPill: View {
    let actionType: PendingPostManager.ActionType
    let timeRemaining: Double
    let totalTime: Double
    let onUndo: () -> Void
    let onEdit: (() -> Void)?
    /// Swipe up to get the pill out of the way. The action is NOT cancelled —
    /// it finishes on schedule in the background.
    var onDismiss: (() -> Void)? = nil

    /// Follows the finger on the way up so the gesture feels attached.
    @State private var dragOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = -32

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: actionType.icon)
                .font(PillSize.regular.iconFont)

            Text("\(actionType.label) in \(max(1, Int(ceil(timeRemaining))))s")
                .monospacedDigit()

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, geo.size.width * (timeRemaining / max(totalTime, 0.1))))
                        .animation(.linear(duration: 0.1), value: timeRemaining)
                }
            }
            .frame(width: 60, height: 4)

            if let onEdit {
                PillButton("Edit", action: onEdit)
            }

            PillButton("Undo", action: onUndo)
        }
        // The buttons set the height.
        .pillCapsule(.accent, vertical: 0)
        .offset(y: dragOffset)
        .opacity(onDismiss == nil ? 1 : 1 - Double(min(1, abs(dragOffset) / 80)) * 0.6)
        // .gesture (not .highPriorityGesture) so Undo/Edit taps still win —
        // SwiftUI routes the tap to the buttons and the drag here.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard onDismiss != nil else { return }
                    // Upward only; a downward pull shouldn't detach the pill.
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    guard let onDismiss else { return }
                    if value.translation.height < Self.dismissThreshold {
                        onDismiss()
                    }
                    withAnimation(Motion.panel) {
                        dragOffset = 0
                    }
                }
        )
        .accessibilityLabel("\(actionType.label) in \(max(1, Int(ceil(timeRemaining)))) seconds")
        .accessibilityHint(onDismiss == nil ? "" : "Swipe up to hide. The \(actionType.label.lowercased()) still completes.")
        .accessibilityAction(named: "Hide") { onDismiss?() }
    }
}

