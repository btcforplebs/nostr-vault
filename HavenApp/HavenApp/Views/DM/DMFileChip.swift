import SwiftUI
import QuickLook

/// A received file that is not a photo or video, decrypted on this device:
/// its kind ("PDF document") and size, opened in Quick Look on a tap, which
/// also offers Share and Save to Files (B11, 2026-11-19).
struct DMFileChip: View {
    let url: URL
    let mime: String

    @State private var preview: URL?

    private var size: String? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        Button { preview = url } label: {
            HStack(spacing: 10) {
                Image(systemName: DMFileKind.symbol(mime))
                    .font(.appSystem(size: 24))
                    .foregroundColor(.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DMFileKind.label(mime))
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(size.map { "\($0) · Tap to open" } ?? "Tap to open")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(minWidth: 200, alignment: .leading)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the file")
        .quickLookPreview($preview)
    }
}
