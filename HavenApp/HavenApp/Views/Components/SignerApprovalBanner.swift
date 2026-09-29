import SwiftUI

// MARK: - Signer Approval Banner
//
// Shown while a request to a remote (NIP-46) signer such as Clave has been
// outstanding long enough that the person probably has to approve it. Without
// it the app just sat there until the request timed out.

struct SignerApprovalBanner: View {
    @ObservedObject private var signer = NIP46Service.shared

    var body: some View {
        VStack {
            if let label = signer.awaitingApproval {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.appSystem(size: 13, weight: .bold))
                            .lineLimit(1)
                        Text("Waiting for your signer app")
                            .font(.appSystem(size: 12, weight: .regular))
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .frame(maxWidth: 340)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.85))
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                )
                .foregroundColor(.white)
                .accessibilityElement(children: .combine)
                .transition(Motion.pillTransition)
            }
        }
        .animation(Motion.bannerIn, value: signer.awaitingApproval)
    }
}
