import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Step 11: Edit Profile

/// The first new-account step (setup screens r3, Logen 2026-11-22): a big
/// photo circle that is itself the photo picker, one name field, one line
/// and Next, drawn like the other setup steps. Nothing is published or
/// uploaded here: Next hands the name and photo back to the wizard, and the
/// photo stays a local JPEG until setup completes and the key can sign
/// (`SetupWizardView.publishNewAccount`). Android's twin is ProfileStep.kt.
struct EditProfileStep: View {
    @Binding var name: String
    @Binding var photoJPEG: Data?
    let onNext: () -> Void

    @State private var appeared = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoError: String?
    /// A working nsec in the name (SecretKeyLeak): Next waits, the text
    /// stays so it can be removed.
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    private static let circleSize: CGFloat = 168

    var body: some View {
        VStack(spacing: 28) {
            Text("Edit Profile")
                .font(.appSystem(size: 28, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 8)

            photoPicker

            VStack(spacing: 12) {
                TextField("", text: $name, prompt: Text("Your name").foregroundColor(WizardColors.textMuted))
                    .textFieldStyle(.plain)
                    .font(.appSystem(size: 22, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { nameFocused = false }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 64)
                    .background(WizardColors.bgCard)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(nameFocused ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: 1)
                    )
                    .accessibilityLabel("Your name")

                Text(nameError ?? photoError ?? "This is how people see you. Change it any time.")
                    .font(.appSystem(size: 15))
                    .foregroundColor(nameError == nil && photoError == nil ? WizardColors.textSecondary : WizardColors.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            WizardPrimaryButton(title: "Next") {
                if SecretKeyLeak.containsSecretKey(name) {
                    nameError = SecretKeyLeak.blockMessage
                } else {
                    nameError = nil
                    nameFocused = false
                    onNext()
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.springEnter, value: appeared)
        .onAppear { appeared = true }
        .onChange(of: name) { _, _ in nameError = nil }
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

    /// The whole circle is the photo button; the orange badge says so.
    private var photoPicker: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(WizardColors.bgElevated)
                    if let preview = photoJPEG.flatMap(Self.previewImage) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "camera.fill")
                                .font(.appSystem(size: 40))
                            Text("Add photo")
                                .font(.appSystem(size: 15, weight: .semibold))
                        }
                        .foregroundColor(WizardColors.textSecondary)
                    }
                }
                .frame(width: Self.circleSize, height: Self.circleSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(WizardColors.borderActive, lineWidth: 2))

                Image(systemName: photoJPEG == nil ? "plus" : "pencil")
                    .font(.appSystem(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(WizardColors.accentGradient))
                    .overlay(Circle().stroke(WizardColors.bgPrimary, lineWidth: 4))
                    .offset(x: -2, y: -2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photoJPEG == nil ? "Add profile photo" : "Change profile photo")
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
