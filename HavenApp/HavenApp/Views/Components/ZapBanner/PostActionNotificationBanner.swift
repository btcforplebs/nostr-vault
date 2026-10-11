import SwiftUI

// MARK: - Post Action Notification Banner

struct PostActionNotificationBanner: View {
    @ObservedObject private var manager = PendingPostManager.shared

    var body: some View {
        VStack(spacing: 6) {
            if manager.isShowing, let actionType = manager.actionType {
                PostActionPill(
                    actionType: actionType,
                    timeRemaining: manager.timeRemaining,
                    totalTime: manager.totalTime,
                    onUndo: { manager.cancel() },
                    onEdit: actionType.canEdit ? { manager.requestEdit() } : nil,
                    onDismiss: { manager.dismissBanner() }
                )
                .transition(Motion.pillTransition)
            } else if let confirmation = manager.confirmation {
                PostConfirmationPill(confirmation: confirmation)
                    .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.isShowing || manager.confirmation != nil ? 12 : 0)
        .animation(Motion.bannerIn, value: manager.isShowing)
        .animation(Motion.bannerIn, value: manager.confirmation?.id)
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
                    .font(.appSystem(size: 12, weight: .bold))
            }
            Text(label)
                .font(.appSystem(size: 13, weight: .bold))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(color)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
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

    private var color: Color {
        switch confirmation.state {
        case .sending:     return confirmation.actionType.themedColor
        // Same green as "Followed".
        case .confirmed:   return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .unconfirmed: return Color(white: 0.35)
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
                .font(.appSystem(size: 14, weight: .bold))

            Text("\(actionType.label) in \(max(1, Int(ceil(timeRemaining))))s")
                .font(.appSystem(size: 14, weight: .bold))

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
                pillButton("Edit", horizontalPadding: 10, action: onEdit)
            }

            pillButton("Undo", horizontalPadding: 12, action: onUndo)
        }
        // The buttons carry the other 10 pt of the pill's vertical padding.
        .padding(.vertical, 2)
        .padding(.horizontal, 24)
        .background(
            Capsule()
                .fill(actionType.themedColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
        .buttonStyle(.plain)
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

    /// The capsule and the pill's height above and below it are all inside the
    /// label, so a tap anywhere on the capsule (or just off it) lands. Padding
    /// outside a plain Button draws but takes no taps.
    private func pillButton(_ title: String, horizontalPadding: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 13, weight: .bold))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.25), in: Capsule())
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
    }
}

