import SwiftUI
#if os(iOS)
import AVFoundation
import AudioToolbox
#endif

// MARK: - QR Scanner (iOS only)

#if os(iOS)
/// Camera QR scanner sheet. Callers may supply a `validate` closure: returning a
/// message rejects the scanned code, shows that message over the camera and keeps
/// scanning, so a wrong QR says so instead of filling the field with something
/// that will fail later.
struct QRScannerView: UIViewControllerRepresentable {
    var title: String = "Scan Nostr QR Code"
    var validate: ((String) -> String?)? = nil
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.title = title
        controller.validate = validate
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    /// Returns nil to accept a scanned code, or a message explaining the rejection.
    var validate: ((String) -> String?)?
    override var title: String? {
        didSet { titleLabel.text = title }
    }
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private var lastRejectedValue: String?
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showMessage("Camera not available")
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func setupOverlay() {
        // Title label
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        // Rejection / error message
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        messageLabel.layer.cornerRadius = 10
        messageLabel.layer.masksToBounds = true
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        // Dismiss button
        let dismissButton = UIButton(type: .system)
        dismissButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        dismissButton.tintColor = .white
        dismissButton.addTarget(self, action: #selector(dismissScanner), for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 60),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -60),
            dismissButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            dismissButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            dismissButton.widthAnchor.constraint(equalToConstant: 32),
            dismissButton.heightAnchor.constraint(equalToConstant: 32),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func dismissScanner() {
        dismiss(animated: true)
    }

    private func showMessage(_ message: String) {
        messageLabel.text = "  \(message)  "
        messageLabel.isHidden = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }

        if let rejection = validate?(value) {
            // Wrong kind of code: say so and keep the camera running for another try.
            // The camera re-reads the same code many times a second, so only react
            // the first time we see it.
            guard lastRejectedValue != value else { return }
            lastRejectedValue = value
            showMessage(rejection)
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            return
        }
        lastRejectedValue = nil

        hasScanned = true
        captureSession?.stopRunning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onCodeScanned?(value)
    }
}
#endif
