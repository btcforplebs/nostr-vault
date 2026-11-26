import SwiftUI

/// Settings › Media Servers › Upload Quality: Standard or Original for photos
/// and videos you post, share, send in live chat or in a DM (Logen
/// 2026-11-26, plan A4). See `UploadQuality`. Apple has no Media & Cache page
/// any more, so this is a section of Media Servers rather than a page of its
/// own. Android twin: `ui/screens/settings/MediaUploadQualityScreen.kt`.
struct MediaUploadQualitySettingsView: View {
    @EnvironmentObject var configService: ConfigService

    private var picked: Binding<String> {
        Binding(
            get: { UploadQuality.normalized(configService.config.uploadQuality) },
            set: { newValue in
                guard newValue != configService.config.uploadQuality else { return }
                configService.config.uploadQuality = newValue
                configService.save()
            }
        )
    }

    var body: some View {
        Section {
            Picker(selection: picked) {
                choice(UploadQuality.standard, title: "Standard",
                       detail: "Photos up to 2048 px, videos at 720p. Smaller files that upload and load faster.")
                choice(UploadQuality.original, title: "Original",
                       detail: "Photos and videos go up as they are. Bigger files, and some media servers refuse large ones.")
            } label: {
                Text("Upload Quality")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("media.uploadQuality")
        } header: {
            Text("Upload Quality")
        } footer: {
            Text("For notes, shares, live chat and messages. Location is removed either way. The Media tab always keeps the original.")
        }
    }

    private func choice(_ key: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.appBody)
            Text(detail)
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("media.uploadQuality.\(key)")
        .tag(key)
    }
}
