import SwiftUI

/// The Everyone banner (EveryoneBanner): what it means, in the shield's
/// orange, and one tap back to your web of trust.
struct EveryoneBannerView: View {
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.slash.fill")
                .foregroundColor(.orange)
            Text(EveryoneBanner.text)
                .font(.appSystem(size: 13))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(EveryoneBanner.back, action: onBack)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
