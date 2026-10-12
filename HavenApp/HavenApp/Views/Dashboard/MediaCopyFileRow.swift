import SwiftUI
import ImageIO

/// One file on this phone that a server is missing, and what the last copy
/// did with it. Shown in the list under Media servers › Copy to servers.
struct MediaCopyFile: Identifiable, Equatable {
    struct Failure: Equatable {
        let server: String
        let reason: String
    }
    enum Status: Equatable {
        case waiting, copying, copied
        case failed([Failure])
    }

    let id: String
    let url: URL
    let kind: Kind
    let size: Int64?
    let added: Date?
    /// The servers that do not have it yet.
    var servers: [String] = []
    var status: Status = .waiting

    var isFailed: Bool { if case .failed = status { return true } else { return false } }

    init(hash: String, url: URL) {
        self.id = hash
        self.url = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attributes?[.size] as? NSNumber)?.int64Value
        self.added = attributes?[.creationDate] as? Date
        self.kind = Kind(BlossomService.sniffContentType(url))
    }

    enum Kind {
        case photo, gif, video, audio, file
        init(_ mime: String) {
            if mime == "image/gif" { self = .gif }
            else if mime.hasPrefix("image/") { self = .photo }
            else if mime.hasPrefix("video/") { self = .video }
            else if mime.hasPrefix("audio/") { self = .audio }
            else { self = .file }
        }
        var name: String {
            switch self {
            case .photo: return "Photo"
            case .gif: return "GIF"
            case .video: return "Video"
            case .audio: return "Audio"
            case .file: return "File"
            }
        }
        var symbol: String {
            switch self {
            case .photo, .gif: return "photo"
            case .video: return "film"
            case .audio: return "waveform"
            case .file: return "doc"
            }
        }
    }

    /// "Photo · 2.4 MB", the way the list names a file.
    var title: String {
        guard let size else { return kind.name }
        return "\(kind.name) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}

struct MediaCopyFileRow: View {
    let file: MediaCopyFile
    let hostFor: (String) -> String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MediaCopyThumbnail(file: file)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.title)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                if case .failed(let failures) = file.status {
                    ForEach(failures, id: \.server) { failure in
                        Text(failures.count > 1 || file.servers.count > 1
                             ? "\(hostFor(failure.server)): \(failure.reason)" : failure.reason)
                            .font(.appSystem(size: 12))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let to = file.servers.map(hostFor).joined(separator: ", ")
        let added = file.added.map { "Added \($0.formatted(date: .abbreviated, time: .omitted))" }
        switch file.status {
        case .copied: return [added, "On every server"].compactMap { $0 }.joined(separator: " · ")
        default: return [added, to.isEmpty ? nil : "Missing on \(to)"].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch file.status {
        case .waiting:
            Text("Waiting")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        case .copying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending")
                    .font(.appSystem(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        case .copied:
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.havenOnline)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.red)
        }
    }
}

/// A small picture of the file, read straight from the vault folder, so the
/// list shows which photo is waiting rather than a hash.
private struct MediaCopyThumbnail: View {
    let file: MediaCopyFile
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.kind.symbol)
                    .font(.appSystem(size: 15))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: file.id) {
            guard file.kind == .photo || file.kind == .gif else { return }
            let url = file.url
            image = await Task.detached(priority: .utility) { Self.thumbnail(url) }.value
        }
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 120,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
