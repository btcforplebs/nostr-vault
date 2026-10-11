import SwiftUI

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

