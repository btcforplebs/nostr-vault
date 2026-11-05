import SwiftUI

#if os(macOS)
import AVFoundation
import AppKit
import Vision

/// The Mac's webcam reading a QR code (a phone screen held up to it):
/// AVFoundation frames into Vision's barcode request. The camera asks for
/// permission the first time and stops when the view goes away.
struct MacWebcamScanner: View {
    let title: String
    var validate: (String) -> String? = { _ in nil }
    let onCode: (String) -> Void
    @StateObject private var camera = MacWebcamCamera()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black)
                switch camera.state {
                case .running:
                    MacCameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                case .starting:
                    ProgressView()
                case .denied:
                    Text("Nostr Vault can't use the camera. Allow it in System Settings › Privacy & Security › Camera.")
                        .font(.appCaption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                case .noCamera:
                    Text("No camera found on this Mac.")
                        .font(.appCaption)
                        .foregroundColor(.white)
                }
            }
            Text(camera.message ?? title)
                .font(.appCaption)
                .foregroundColor(camera.message == nil ? .secondary : .orange)
                .multilineTextAlignment(.center)
        }
        .onAppear {
            camera.onCode = { code in
                if let message = validate(code) {
                    camera.message = message
                    return false
                }
                onCode(code)
                return true
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
}

@MainActor
final class MacWebcamCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State { case starting, running, denied, noCamera }

    @Published var state: State = .starting
    @Published var message: String?
    /// True when the code was taken, so the camera stops reading.
    var onCode: ((String) -> Bool)?

    nonisolated let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.havenapp.pairing.webcam")
    private nonisolated(unsafe) var lastSeen: String?
    private nonisolated(unsafe) var done = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in granted ? self.configure() : (self.state = .denied) }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            state = .noCamera
            return
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        let session = session
        queue.async {
            session.beginConfiguration()
            if session.inputs.isEmpty, session.canAddInput(input) { session.addInput(input) }
            if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
            Task { @MainActor in self.state = .running }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard !done, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        guard let code = request.results?.compactMap(\.payloadStringValue).first, code != lastSeen else { return }
        lastSeen = code
        Task { @MainActor in
            guard !self.done, let onCode = self.onCode else { return }
            if onCode(code) {
                self.done = true
                self.stop()
            }
        }
    }
}

/// The live camera picture, mirrored as a webcam is expected to look.
private struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
