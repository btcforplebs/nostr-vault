import SwiftUI

/// The line under a message bubble: its time, or for your own message
/// "Sending…" until a relay of theirs takes it, and "Not sent" with Try again
/// and Remove when none does (web: ConversationScreen's pending / failed row).
struct DMSendStatusLine: View {
    let message: DMMessage
    /// Try again is offered (DMService.canResend).
    var canRetry: Bool = false
    var onRetry: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    @State private var retrying = false

    var body: some View {
        Group {
            if message.isSending {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Sending…")
                }
                .foregroundColor(.secondary.opacity(0.8))
                .accessibilityElement(children: .combine)
            } else if message.isFailed {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 10) {
                        Label("Not sent", systemImage: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        if canRetry, let onRetry {
                            Button(retrying ? "Sending…" : "Try again") {
                                retrying = true
                                onRetry()
                            }
                            .disabled(retrying)
                        }
                        if let onRemove {
                            Button("Remove", role: .destructive, action: onRemove)
                        }
                    }
                    .buttonStyle(.borderless)
                    if let why = message.sendFailure {
                        Text(why)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.trailing)
                    }
                }
            } else {
                Text(message.timestamp.formatted(.relative(presentation: .numeric)))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .font(.appSystem(size: 11))
        .padding(.horizontal, 6)
        // A new failure (a Try again that failed too) starts the buttons fresh.
        .onChange(of: message.sendFailure) { _, _ in retrying = false }
    }
}
