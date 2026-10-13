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
                .font(PillSize.regular.iconFont)

            Text("Reaction removed")

            PillButton("Undo", action: onUndo)
        }
        // The 44 pt Undo sets the height.
        .pillCapsule(.neutral, vertical: 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reaction removed")
        .accessibilityAction(named: "Undo", onUndo)
    }
}

