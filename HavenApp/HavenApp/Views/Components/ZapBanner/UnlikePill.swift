import SwiftUI

// MARK: - Unlike Notification Manager

@MainActor
class UnlikeNotificationManager: ObservableObject {
    static let shared = UnlikeNotificationManager()

    @Published var isShowing = false
    @Published var timeRemaining: Double = 3.0
    private var task: Task<Void, Never>?
    private var onUnlike: (() -> Void)?
    private var onUndo: (() -> Void)?

    /// Shows the pill for a reaction that was just removed. `onUnlike` makes
    /// the removal final when the pill runs out; Undo calls `onUndo` instead.
    func startCountdown(onUnlike: @escaping () -> Void, onUndo: @escaping () -> Void = {}) {
        // One pill at a time: a removal still counting down becomes final.
        commit()
        self.onUnlike = onUnlike
        self.onUndo = onUndo
        timeRemaining = 3.0
        withAnimation(Motion.bannerIn) { isShowing = true }
        task = Task {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                await MainActor.run { self.timeRemaining -= 0.1 }
            }
            if Task.isCancelled { return }
            await MainActor.run { self.commit() }
        }
    }

    /// Makes a pending removal final now.
    func commit() {
        let action = onUnlike
        dismiss()
        action?()
    }

    /// Undo: puts the removed reaction back.
    func cancel() {
        let action = onUndo
        dismiss()
        action?()
    }

    private func dismiss() {
        task?.cancel()
        task = nil
        onUnlike = nil
        onUndo = nil
        if isShowing {
            withAnimation(Motion.bannerOut) { isShowing = false }
        }
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

            Text("Reaction removed")
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
        .accessibilityLabel("Reaction removed")
    }
}

