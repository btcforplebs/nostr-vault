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
        VStack(spacing: 0) {
            ForEach(manager.notifications) { notification in
                PillSlot("upload-\(notification.id)", level: notification.pillLevel) {
                    UploadPill(notification: notification)
                }
            }
        }
    }
}

extension MediaUploadNotification {
    var pillLevel: PillLevel {
        if case .failed = status { return .error }
        return .result
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
                    .lineLimit(1)
                
                if notification.status == .uploading {
                    Text("\(Int(notification.progress * 100))%")
                        .font(.appSystem(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .pillCapsule(tone)
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
                .font(PillSize.regular.iconFont)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(PillSize.regular.iconFont)
        }
    }

    private var label: String {
        switch notification.status {
        case .uploading:
            return "Uploading \(notification.filename)"
        case .success:
            return "Uploaded \(notification.filename)"
        case .failed(let reason):
            return "Upload failed: \(reason)"
        }
    }

    private var tone: PillTone {
        switch notification.status {
        case .uploading: return .accent
        case .success:   return .success
        case .failed:    return .error
        }
    }
}

