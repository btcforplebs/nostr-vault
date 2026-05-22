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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        return notification.id
    }

    func markSuccess(id: UUID) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .success
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { isShowing = true }
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
                withAnimation(.easeOut(duration: 0.4)) { self.isShowing = false }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        onUnlike = nil
        withAnimation(.easeOut(duration: 0.4)) { isShowing = false }
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
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.8))
                ))
            }
            ForEach(zapManager.notifications) { notification in
                ZapPill(notification: notification)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: zapManager.notifications.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: unlikeManager.isShowing)
    }
}

// MARK: - Unlike Pill

struct UnlikePill: View {
    let timeRemaining: Double
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 12, weight: .bold))

            Text("Unliking in \(max(1, Int(ceil(timeRemaining))))s")
                .font(.system(size: 13, weight: .bold))

            Button("Undo") { onUndo() }
                .font(.system(size: 12, weight: .bold))
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
                .font(.system(size: 13, weight: .bold))

            // Sats amount
            Text("\(notification.amountSats) sats")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch notification.status {
        case .sending:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .opacity(pulseOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.4
                    }
                }
        case .success:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        let dismissDelay: TimeInterval = {
            if case .failed = kind { return 5.0 }
            return 3.0
        }()
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            withAnimation(.easeOut(duration: 0.4)) {
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
    }
}

// MARK: - Follow Pill

struct FollowPill: View {
    let notification: FollowNotification

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))

            Text(label)
                .font(.system(size: 13, weight: .bold))
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .success
                notifications[idx].progress = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
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
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
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
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                
                if notification.status == .uploading {
                    Text("\(Int(notification.progress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                .font(.system(size: 14, weight: .bold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
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

