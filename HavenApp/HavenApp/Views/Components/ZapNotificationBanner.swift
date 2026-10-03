import SwiftUI

// MARK: - Zap Notification Model

struct ZapNotification: Identifiable {
    let id = UUID()
    let recipientName: String
    let amountSats: Int
    var status: ZapStatus

    enum ZapStatus: Equatable {
        case sending
        case success
        case failed(String)
    }
}

// MARK: - Zap Notification Manager

@MainActor
class ZapNotificationManager: ObservableObject {
    static let shared = ZapNotificationManager()

    @Published var notifications: [ZapNotification] = []

    func addZap(recipientName: String, amountSats: Int) -> UUID {
        let notification = ZapNotification(
            recipientName: recipientName,
            amountSats: amountSats,
            status: .sending
        )
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        return notification.id
    }

    func markSuccess(id: UUID) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .success
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }
}

// MARK: - Unlike Notification Manager

@MainActor
class UnlikeNotificationManager: ObservableObject {
    static let shared = UnlikeNotificationManager()

    @Published var isShowing = false
    @Published var timeRemaining: Double = 3.0
    private var task: Task<Void, Never>?
    private var onUnlike: (() -> Void)?

    func startCountdown(onUnlike: @escaping () -> Void) {
        cancel()
        self.onUnlike = onUnlike
        timeRemaining = 3.0
        withAnimation(Motion.bannerIn) { isShowing = true }
        task = Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                await MainActor.run { self.timeRemaining -= 0.1 }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.onUnlike?()
                self.onUnlike = nil
                withAnimation(Motion.bannerOut) { self.isShowing = false }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        onUnlike = nil
        withAnimation(Motion.bannerOut) { isShowing = false }
    }
}

// MARK: - Zap Notification Banner (floating pill)

struct ZapNotificationBanner: View {
    @ObservedObject private var zapManager = ZapNotificationManager.shared
    @ObservedObject private var unlikeManager = UnlikeNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            if unlikeManager.isShowing {
                UnlikePill(timeRemaining: unlikeManager.timeRemaining) {
                    unlikeManager.cancel()
                }
                .transition(Motion.pillTransition)
            }
            ForEach(zapManager.notifications) { notification in
                ZapPill(notification: notification)
                    .transition(Motion.pillTransition)
            }
        }
        .padding(.top, (unlikeManager.isShowing || !zapManager.notifications.isEmpty) ? 12 : 0)
        .animation(Motion.bannerIn, value: zapManager.notifications.map(\.id))
        .animation(Motion.bannerIn, value: unlikeManager.isShowing)
    }
}

// MARK: - Unlike Pill

struct UnlikePill: View {
    let timeRemaining: Double
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.slash.fill")
                .font(.appSystem(size: 12, weight: .bold))

            Text("Unliking in \(max(1, Int(ceil(timeRemaining))))s")
                .font(.appSystem(size: 13, weight: .bold))

            Button("Undo") { onUndo() }
                .font(.appSystem(size: 12, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.25))
                .clipShape(Capsule())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(Color.red.opacity(0.85))
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
        .buttonStyle(.plain)
        .accessibilityLabel("Unliking in \(max(1, Int(ceil(timeRemaining)))) seconds")
    }
}

// MARK: - Zap Pill (matches "New Posts" capsule style)

struct ZapPill: View {
    let notification: ZapNotification
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            // Status icon
            statusIcon

            // Label
            Text(pillLabel)
                .font(.appSystem(size: 13, weight: .bold))

            // Sats amount
            Text("\(notification.amountSats) sats")
                .font(.appSystem(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pillLabel), \(notification.amountSats) sats")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch notification.status {
        case .sending:
            Image(systemName: "bolt.fill")
                .font(.appSystem(size: 12, weight: .bold))
                .opacity(pulseOpacity)
                .onAppear {
                    // Same reason as the feed skeleton: without the guard the
                    // bolt would sit dimmed at 0.4 for the whole send.
                    guard let loop = Motion.ambientPulse else { return }
                    withAnimation(loop) { pulseOpacity = 0.4 }
                }
        case .success:
            Image(systemName: "bolt.fill")
                .font(.appSystem(size: 12, weight: .bold))
        case .failed:
            Image(systemName: "xmark")
                .font(.appSystem(size: 12, weight: .bold))
        }
    }

    private var pillLabel: String {
        switch notification.status {
        case .sending: return "Zapping \(notification.recipientName)"
        case .success: return "Zapped \(notification.recipientName)"
        case .failed:  return "Zap failed"
        }
    }

    private var pillColor: Color {
        switch notification.status {
        case .sending: return .orange
        case .success: return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .failed:  return .red.opacity(0.85)
        }
    }
}

// MARK: - Follow Notification Model

struct FollowNotification: Identifiable {
    let id = UUID()
    let recipientName: String
    let kind: Kind

    enum Kind: Equatable {
        case followed
        case unfollowed
        case failed(String)
    }
}

// MARK: - Follow Notification Manager

@MainActor
class FollowNotificationManager: ObservableObject {
    static let shared = FollowNotificationManager()

    @Published var notifications: [FollowNotification] = []

    func add(recipientName: String, kind: FollowNotification.Kind) {
        let notification = FollowNotification(recipientName: recipientName, kind: kind)
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        let dismissDelay: TimeInterval = {
            if case .failed = kind { return 5.0 }
            return 3.0
        }()
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            withAnimation(Motion.bannerOut) {
                self?.notifications.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Follow Notification Banner

struct FollowNotificationBanner: View {
    @ObservedObject private var manager = FollowNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                FollowPill(notification: notification)
                    .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.notifications.isEmpty ? 0 : 12)
        .animation(Motion.bannerIn, value: manager.notifications.map(\.id))
    }
}

// MARK: - Follow Pill

struct FollowPill: View {
    let notification: FollowNotification

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.appSystem(size: 12, weight: .bold))

            Text(label)
                .font(.appSystem(size: 13, weight: .bold))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var iconName: String {
        switch notification.kind {
        case .followed:   return "person.badge.plus"
        case .unfollowed: return "person.badge.minus"
        case .failed:     return "xmark"
        }
    }

    private var label: String {
        switch notification.kind {
        case .followed:           return "Followed \(notification.recipientName)"
        case .unfollowed:         return "Unfollowed \(notification.recipientName)"
        case .failed(let reason): return reason
        }
    }

    private var pillColor: Color {
        switch notification.kind {
        case .followed:   return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .unfollowed: return Color(white: 0.35)
        case .failed:     return .red.opacity(0.85)
        }
    }
}

// MARK: - Media Upload Notification Model

struct MediaUploadNotification: Identifiable {
    let id = UUID()
    let filename: String
    var status: UploadStatus
    var progress: Double

    enum UploadStatus: Equatable {
        case uploading
        case success
        case failed(String)
    }
}

// MARK: - Media Upload Notification Manager

@MainActor
class MediaUploadNotificationManager: ObservableObject {
    static let shared = MediaUploadNotificationManager()

    @Published var notifications: [MediaUploadNotification] = []

    func add(filename: String) -> UUID {
        let notification = MediaUploadNotification(
            filename: filename,
            status: .uploading,
            progress: 0.0
        )
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        return notification.id
    }

    func updateProgress(id: UUID, progress: Double) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].progress = progress
        }
    }

    func markSuccess(id: UUID) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .success
                notifications[idx].progress = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }
}

// MARK: - Media Upload Notification Banner

struct MediaUploadNotificationBanner: View {
    @ObservedObject private var manager = MediaUploadNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                UploadPill(notification: notification)
                    .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.notifications.isEmpty ? 0 : 12)
        .animation(Motion.bannerIn, value: manager.notifications.map(\.id))
    }
}

// MARK: - Post Action Notification Banner

struct PostActionNotificationBanner: View {
    @ObservedObject private var manager = PendingPostManager.shared

    var body: some View {
        VStack(spacing: 6) {
            if manager.isShowing, let actionType = manager.actionType {
                PostActionPill(
                    actionType: actionType,
                    timeRemaining: manager.timeRemaining,
                    onUndo: { manager.cancel() },
                    onEdit: actionType.canEdit ? { manager.requestEdit() } : nil,
                    onDismiss: { manager.dismissBanner() }
                )
                .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.isShowing ? 12 : 0)
        .animation(Motion.bannerIn, value: manager.isShowing)
    }
}

// MARK: - Post Action Pill

struct PostActionPill: View {
    let actionType: PendingPostManager.ActionType
    let timeRemaining: Double
    let onUndo: () -> Void
    let onEdit: (() -> Void)?
    /// Swipe up to get the pill out of the way. The action is NOT cancelled —
    /// it finishes on schedule in the background.
    var onDismiss: (() -> Void)? = nil

    private let totalTime = PendingPostManager.ActionType.countdownDuration

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
                        .frame(width: max(0, geo.size.width * (timeRemaining / totalTime)))
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

// MARK: - Upload Pill

struct UploadPill: View {
    let notification: MediaUploadNotification
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 13, weight: .bold))
                    .lineLimit(1)
                
                if notification.status == .uploading {
                    Text("\(Int(notification.progress * 100))%")
                        .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch notification.status {
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.appSystem(size: 14, weight: .bold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.appSystem(size: 14, weight: .bold))
        }
    }

    private var label: String {
        switch notification.status {
        case .uploading:
            return "Uploading \(notification.filename)"
        case .success:
            return "Successfully Uploaded \(notification.filename)"
        case .failed(let reason):
            return "Upload failed: \(reason)"
        }
    }

    private var gradientColors: [Color] {
        switch notification.status {
        case .uploading:
            return [Color.havenPurple, Color.havenPurpleLight]
        case .success:
            return [Color(red: 0.2, green: 0.8, blue: 0.6), Color(red: 0.1, green: 0.6, blue: 0.4)]
        case .failed:
            return [Color.red.opacity(0.85), Color.red.opacity(0.6)]
        }
    }
}

// MARK: - Action Toast Manager

@MainActor
class ActionToastManager: ObservableObject {
    static let shared = ActionToastManager()

    struct Toast: Identifiable {
        let id = UUID()
        let icon: String
        let message: String
        let color: Color
    }

    @Published var notifications: [Toast] = []

    func show(icon: String, message: String, color: Color? = nil) {
        let toast = Toast(icon: icon, message: message, color: color ?? Color.havenPurple)
        notifications.append(toast)

        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(Motion.bannerOut) {
                notifications.removeAll { $0.id == toast.id }
            }
        }
    }
}

// MARK: - Action Toast Banner

struct ActionToastBanner: View {
    @ObservedObject private var manager = ActionToastManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { toast in
                HStack(spacing: 6) {
                    Image(systemName: toast.icon)
                        .font(.appSystem(size: 12, weight: .bold))
                    Text(toast.message)
                        .font(.appSystem(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .background(
                    Capsule()
                        .fill(toast.color)
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                )
                .foregroundColor(.white)
                .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.notifications.isEmpty ? 0 : 12)
        .animation(Motion.bannerIn, value: manager.notifications.map(\.id))
    }
}

