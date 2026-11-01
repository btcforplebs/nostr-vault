import SwiftUI

/// What an attachment's upload is doing, drawn over its thumbnail: a
/// progress ring while it goes up, a clock while it is saved on this device
/// only, and Retry when it did not upload. Nothing once it is hosted.
struct AttachmentUploadBadge: View {
    let state: ComposerUploadState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .waiting:
            ring(progress: 0)
                .accessibilityLabel("Waiting to upload")
        case .uploading(let progress):
            ring(progress: progress)
                .accessibilityLabel("Uploading")
                .accessibilityValue("\(Int(progress * 100)) percent")
        case .hosted:
            EmptyView()
        case .savedOnDevice:
            Image(systemName: "clock.arrow.circlepath")
                .font(.appSystem(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.55)))
                .help("Saved on this device. It goes out when one of your media servers answers.")
                .accessibilityLabel("Saved on this device, waiting for a media server")
        case .failed(let message):
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(7)
                    .background(Circle().fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel("Didn't upload. Retry")
            .accessibilityHint(message)
        }
    }

    private func ring(progress: Double) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.45))
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 3)
                .padding(4)
            Circle()
                .trim(from: 0, to: max(0.03, progress))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(width: 30, height: 30)
    }
}
