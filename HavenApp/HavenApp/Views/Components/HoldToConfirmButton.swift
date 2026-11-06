import SwiftUI

/// A destructive button that only fires after being held down for `seconds`.
/// The fill grows while it is held; letting go early resets it and does
/// nothing. With VoiceOver: double-tap and hold.
struct HoldToConfirmButton: View {
    let title: String
    let seconds: Double
    let enabled: Bool
    let action: () -> Void

    @State private var holding = false
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(enabled ? 0.35 : 0.15))
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 10).fill(Color.red)
                    .frame(width: geo.size.width * progress)
            }
            Text(holding ? "Keep holding\u{2026}" : title)
                .font(.appBody.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.6)
        .onLongPressGesture(minimumDuration: seconds, maximumDistance: 40, perform: {
            guard enabled else { return }
            holding = false
            action()
        }, onPressingChanged: { pressing in
            guard enabled else { return }
            holding = pressing
            if pressing {
                withAnimation(.linear(duration: seconds)) { progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Double-tap and hold for \(Int(seconds)) seconds.")
        .accessibilityAddTraits(.isButton)
        .disabled(!enabled)
    }
}
