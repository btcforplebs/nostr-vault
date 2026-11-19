import SwiftUI
import AVKit

/// The system AirPlay picker for the video player, white and sized like the
/// control bar's other buttons (the music player has its own AirPlayButton).
/// It lists AirPlay and Bluetooth outputs and sends the video along.
struct VideoAirPlayButton: View {
    var onTap: (() -> Void)? = nil

    var body: some View {
        RoutePicker(onTap: onTap)
            .frame(width: 34, height: 34)
            .accessibilityLabel("AirPlay")
    }
}

#if os(iOS)
private struct RoutePicker: UIViewRepresentable {
    let onTap: (() -> Void)?

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onTap?() }
    }
}
#else
private struct RoutePicker: NSViewRepresentable {
    let onTap: (() -> Void)?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onTap?() }
    }
}
#endif
