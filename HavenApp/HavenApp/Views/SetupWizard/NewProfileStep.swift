import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Step 11: New Profile

/// Name and photo for a key generated in this run. Nothing is published here:
/// the wizard publishes the kind 0 once setup completes and the key can sign.
struct NewProfileStep: View {
    @Binding var name: String
    @Binding var photoJPEG: Data?
    let onContinue: () -> Void

    @State private var appeared = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            VStack(spacing: 8) {
                Text("Your Profile")
                    .font(.appSystem(size: 24, weight: .bold))
                    .foregroundColor(WizardColors.textPrimary)
                Text("This is how people will see you. You can change it later.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(WizardColors.bgElevated)
                            .frame(width: 104, height: 104)
                        if let preview = photoJPEG.flatMap(Self.previewImage) {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 104, height: 104)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.appSystem(size: 28))
                                .foregroundColor(WizardColors.textMuted)
                        }
                    }
                    .overlay(Circle().stroke(WizardColors.borderActive, lineWidth: 1))
                    Text(photoJPEG == nil ? "Add Photo" : "Change Photo")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.accentPrimary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoJPEG == nil ? "Add profile photo" : "Change profile photo")

            if let photoError {
                Text(photoError)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.textSecondary)
            }

            WizardInputField(label: "Name", text: $name, placeholder: "Your name")

            Spacer()

            VStack(spacing: 12) {
                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)
                WizardSkipLink(title: "Skip for Now") {
                    name = ""
                    photoJPEG = nil
                    onContinue()
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.springEnter, value: appeared)
        .onAppear { appeared = true }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let jpeg = data.flatMap({ Self.profileJPEG(from: $0) }) {
                        photoJPEG = jpeg
                        photoError = nil
                    } else {
                        photoError = "Couldn't read that photo. Try another."
                    }
                }
            }
        }
    }

    /// A square-friendly JPEG no larger than 512 px on its longest side.
    /// Drawing a fresh thumbnail also leaves the original's metadata behind,
    /// location included; the upload strips it again regardless.
    static func profileJPEG(from data: Data, maxPixel: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    static func previewImage(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
