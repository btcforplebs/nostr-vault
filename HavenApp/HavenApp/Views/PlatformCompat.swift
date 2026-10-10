import UniformTypeIdentifiers
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Platform Image

#if canImport(AppKit)
typealias PlatformImage = NSImage
let isIOSDevice = false
#elseif canImport(UIKit)
typealias PlatformImage = UIImage
let isIOSDevice = true
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    #if canImport(UIKit)
    convenience init?(cgImage: CGImage, size: CGSize) {
        self.init(cgImage: cgImage)
    }
    #endif
}

// MARK: - Platform Colors

extension Color {
    @MainActor
    /// Resting content: cards, grouped rows, controls, sheets. NOT the page —
    /// a full-bleed background wants `platformWindowBackground`.
    static var platformControlBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        #if canImport(AppKit)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.secondarySystemGroupedBackground)
        #endif
    }

    @MainActor
    /// The page. Everything else sits on this.
    static var platformWindowBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface0
        }
        return Color(red: 0.08, green: 0.08, blue: 0.1)
    }

    @MainActor
    static var platformTextBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        #if canImport(AppKit)
        return Color(NSColor.textBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    @MainActor
    static var platformSecondaryGroupedBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        return Color(red: 0.12, green: 0.12, blue: 0.16)
    }

    @MainActor
    static var platformTertiaryGroupedBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface2
        }
        return Color(red: 0.15, green: 0.15, blue: 0.2)
    }

    @MainActor
    static var platformSeparator: Color {
        if ConfigService.shared.config.useOLED {
            return .borderHairline
        }
        return Color(red: 0.2, green: 0.2, blue: 0.25)
    }

    /// Card/container backgrounds (StatsCard, RelayRow, KindRow, etc.)
    @MainActor
    static var platformCardBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface1
        }
        return Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.6)
    }

    /// The seam around a card whose fill already separates it from the page.
    /// If the border is the only thing making a control visible, that control
    /// wants `Color.borderStrong` instead — this one does not meet 3:1.
    @MainActor
    static var platformCardBorder: Color {
        if ConfigService.shared.config.useOLED {
            return .borderHairline
        }
        return Color.white.opacity(0.04)
    }

    /// Console/terminal header background
    @MainActor
    static var platformConsoleHeaderBackground: Color {
        if ConfigService.shared.config.useOLED {
            return .surface2
        }
        return Color(red: 0.12, green: 0.12, blue: 0.15)
    }
}

// MARK: - Clipboard

struct PlatformClipboard {
    static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }

    /// Read string from clipboard (for URLs)
    static func getString() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #elseif canImport(UIKit)
        return UIPasteboard.general.string
        #endif
    }

    /// Read image data from clipboard
    static func getImageData() -> Data? {
        #if canImport(AppKit)
        guard let items = NSPasteboard.general.pasteboardItems else { return nil }
        for item in items {
            if let data = item.data(forType: NSPasteboard.PasteboardType.png) { return data }
            if let data = item.data(forType: NSPasteboard.PasteboardType.tiff) { return data }
            // Also check for generic image type
            if let data = item.data(forType: NSPasteboard.PasteboardType("public.image")) { return data }
        }
        return nil
        #elseif canImport(UIKit)
        // Try to get raw data in original format to preserve GIFs
        if let data = UIPasteboard.general.data(forPasteboardType: "com.compuserve.gif") { return data }
        if let data = UIPasteboard.general.data(forPasteboardType: "public.png") { return data }
        // Fallback: convert UIImage (loses GIF animation)
        return UIPasteboard.general.image?.jpegData(compressionQuality: 0.85)
        #endif
    }

    /// A video on the clipboard, copied out to a temporary file so it can go
    /// through the same upload as a file picked with + -> Files. Nil when the
    /// clipboard holds no video.
    ///
    /// Videos are read as files, never as `Data`: a copied clip can be
    /// hundreds of megabytes, and the image path's `data(forPasteboardType:)`
    /// would pull all of it into memory.
    static func copyVideoToTemporaryFile() async -> URL? {
        #if canImport(AppKit)
        // Finder puts file URLs on the pasteboard. The file is already on disk.
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.first { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        }
        #elseif canImport(UIKit)
        for provider in UIPasteboard.general.itemProviders {
            guard let typeID = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .movie) == true
            }) else { continue }
            let ext = UTType(typeID)?.preferredFilenameExtension ?? "mov"
            return await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                    // The provided file is deleted when this handler returns.
                    guard let url else { continuation.resume(returning: nil); return }
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pasted-video-\(UUID().uuidString.prefix(8))")
                        .appendingPathExtension(ext)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
        #endif
    }

    /// Check if clipboard contains an image
    static func hasImage() -> Bool {
        #if canImport(AppKit)
        guard let types = NSPasteboard.general.types else { return false }
        return types.contains(.png) || types.contains(.tiff)
            || types.contains(NSPasteboard.PasteboardType("public.image"))
        #elseif canImport(UIKit)
        return UIPasteboard.general.hasImages
        #endif
    }
}

// MARK: - Open URL

struct PlatformURL {
    @MainActor
    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Screen Scale

struct PlatformScreen {
    static var backingScaleFactor: CGFloat {
        #if canImport(AppKit)
        NSScreen.main?.backingScaleFactor ?? 2.0
        #else
        UIScreen.main.scale
        #endif
    }
}

// MARK: - Form Style Compat

extension View {
    @ViewBuilder
    func groupedFormStyleCompat() -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }

}

#if os(iOS)
/// Walks up to the presenting UIHostingController's view and clears its
/// background so a `.fullScreenCover` can show a translucent backdrop instead
/// of the default opaque system background.
struct ClearFullScreenBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

extension View {
    @ViewBuilder
    func applyGlassCapsule() -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        Capsule()
                            .glassEffect(.clear, in: .capsule)
                    )
            )
        } else {
            self
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .opacity(isOLED ? 0.65 : 0.35)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(isOLED ? 0.20 : 0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
        }
        #else
        self
        #endif
    }
    
    @ViewBuilder
    func applyGlassCircle() -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        Circle()
                            .glassEffect(.regular, in: .circle)
                    )
            )
        } else {
            self
                .background(
                    Color.clear
                        .overlay(
                            Circle()
                                .fill(.ultraThinMaterial)
                                .opacity(isOLED ? 0.85 : 1.0)
                        )
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(isOLED ? 0.30 : 0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func applyGlassRect(cornerRadius: CGFloat = 16) -> some View {
        #if os(iOS)
        let isOLED = ConfigService.shared.config.useOLED
        if #available(iOS 26.0, *) {
            self.background(
                Color.clear
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                    )
            )
        } else {
            self
                .background(
                    Color.clear
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(.ultraThinMaterial)
                                .opacity(isOLED ? 0.85 : 1.0)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.white.opacity(isOLED ? 0.30 : 0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        #else
        self
        #endif
    }

    /// Consistent bottom padding so scroll content clears the floating tab bar on iOS.
    @ViewBuilder
    func tabBarBottomPadding() -> some View {
        self
    }

    /// Conditionally apply a modifier only when a condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Floating tab bar

private struct FloatingTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Height of the iPhone's floating bottom tab bar. It is laid over the tab
    /// content rather than inset into it, so the content's safe area never
    /// includes it — a full-bleed screen has to clear it by hand. Zero where
    /// there is no bottom bar (the iPad sidebar, macOS).
    var floatingTabBarHeight: CGFloat {
        get { self[FloatingTabBarHeightKey.self] }
        set { self[FloatingTabBarHeightKey.self] = newValue }
    }
}

/// Lifts a floating action button (Post, Relay, Blossom) clear of the iPhone's
/// floating tab bar. Where there is no bar -- the iPad split -- the fixed 90pt
/// lift left the button hovering over the list's cards, so it drops to the
/// ordinary margin there.
private struct FloatingActionBottomPadding: ViewModifier {
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    func body(content: Content) -> some View {
        content.padding(.bottom, tabBarHeight > 0 ? 90 : 20)
    }
}

extension View {
    func floatingActionBottomPadding() -> some View {
        modifier(FloatingActionBottomPadding())
    }
}

// MARK: - Width-driven layout

/// How a screen lays itself out from the room it actually has, rather than from
/// which device it is on. A phone-width column inside the iPad split is
/// phone-width, and a sheet is narrower than the window it opens over, so the
/// pane's own width is the only thing worth asking.
enum AdaptiveLayout {
    /// A line of text stops being readable much past this measure. A wide pane
    /// centres its content inside it instead of running a note across 13in.
    static let readableWidth: CGFloat = 700

    /// Width a wide pane gives a docked side panel: the trust card beside the
    /// Web of Trust globe.
    static let sidePanelWidth: CGFloat = 360

    /// `AdaptiveGridLayout.columnCount` as a `LazyVGrid`'s columns, for the
    /// width this platform lays out from. `width` is the grid's own width with
    /// its insets already taken off.
    static func columns(width: CGFloat, ideal: CGFloat, spacing: CGFloat,
                        minimum: Int, maximum: Int) -> [GridItem] {
        let count = AdaptiveGridLayout.columnCount(forWidth: Double(layoutWidth(width)),
                                                   ideal: Double(ideal), spacing: Double(spacing),
                                                   minimum: minimum, maximum: maximum)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// Only the iPad lays itself out from its width here. A large iPhone in
    /// landscape is wide too, and b21's parity work is not allowed to move the
    /// phone; the Mac already has its own counts and its own two-pane layouts.
    static var usesWidth: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The width a screen should lay out from: its own on iPad, and 0 — "no
    /// measurement, keep the phone's layout" — everywhere else.
    static func layoutWidth(_ width: CGFloat) -> CGFloat {
        usesWidth ? width : 0
    }
}

private struct ReadableWidthCap: ViewModifier {
    let maxWidth: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if AdaptiveLayout.usesWidth {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

extension View {
    /// Holds content to a readable measure and centres it in whatever room is
    /// left over. A no-op wherever there is no room to spare, which is every
    /// phone width.
    func readableWidthCap(_ maxWidth: CGFloat = AdaptiveLayout.readableWidth) -> some View {
        modifier(ReadableWidthCap(maxWidth: maxWidth))
    }

    /// A small sheet stays small on iPad. `presentationDetents` is a phone-only
    /// API: the iPad ignores it and opens the standard form sheet, so a 380pt
    /// zap keypad arrived as a half-empty page. Sizing to the content is the
    /// same intent the detents express on the phone.
    @ViewBuilder
    func smallSheetSizing() -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *), AdaptiveLayout.usesWidth {
            self.presentationSizing(.fitted)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// The view's own width, reported whenever it changes.
    func measureWidth(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { action($0) }
    }
}

// MARK: - ⌘R

/// Answers ⌘R (`havenRefreshTab`) for one tab, while `isActive` says this view
/// is the one showing. A modifier rather than an inline receiver keeps the big
/// views' modifier chains inside the type checker's budget.
struct RefreshesOnTabCommand: ViewModifier {
    let tab: Int
    var isActive: () -> Bool = { true }
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .havenRefreshTab)) { note in
            guard (note.object as? Int) == tab, isActive() else { return }
            action()
        }
    }
}

// MARK: - Dropped Media

/// A photo or video dragged in from another app (Photos, Files, Safari) or
/// from elsewhere in this one, read off its item provider.
enum DroppedMedia {
    /// The image's own bytes, so a GIF still moves; the caller re-encodes.
    case image(Data, UTType)
    /// A copy in the temporary directory, which the caller then owns: the
    /// provider deletes its own file as soon as the load returns.
    case video(URL, UTType)

    /// What a drop target accepts. Videos first, so a Live Photo's still
    /// doesn't win over a clip that also offers a poster image.
    static let acceptedTypes: [UTType] = [.movie, .image]

    /// `acceptingVideo: false` reads a Live Photo or a clip with a poster as
    /// its still, so a caller that only takes images never receives a video
    /// copy it would have to clean up.
    static func load(_ provider: NSItemProvider, acceptingVideo: Bool) async -> DroppedMedia? {
        let types = provider.registeredContentTypes
        if acceptingVideo, let movieType = types.first(where: { $0.conforms(to: .movie) }) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(for: movieType, openInPlace: false) { url, _, _ in
                    guard let url else { return continuation.resume(returning: nil) }
                    let ext = url.pathExtension.isEmpty ? (movieType.preferredFilenameExtension ?? "mov") : url.pathExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                        .appendingPathExtension(ext)
                    do {
                        try FileManager.default.copyItem(at: url, to: dest)
                        continuation.resume(returning: .video(dest, UTType(filenameExtension: ext) ?? movieType))
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        if let imageType = types.first(where: { $0.conforms(to: .image) }) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: imageType) { data, _ in
                    continuation.resume(returning: data.map { .image($0, imageType) })
                }
            }
        }
        return nil
    }
}

extension View {
    /// The outline a drop target draws while something is dragged over it.
    func dropTargetHighlight(_ isTargeted: Bool, cornerRadius: CGFloat = 12) -> some View {
        overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.havenPurple, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.havenPurple.opacity(0.06), in: RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }
        }
    }
}

#if os(iOS)
/// ⌘V on an iPad keyboard attaches the image on the clipboard. The focused
/// text field owns ⌘V for text, so the key is bound only while the clipboard
/// holds an image and no text or link: pasting words into the field is never
/// taken away from it.
struct PastesClipboardImage: ViewModifier {
    let action: () -> Void
    @State private var clipboardHoldsOnlyImage = false
    /// From the app notifications, not `scenePhase`: under this app's UIKit
    /// scene delegate `scenePhase` never reads `.active`.
    @State private var appIsActive = true

    func body(content: Content) -> some View {
        content
            .background {
                if clipboardHoldsOnlyImage {
                    Button("Paste Photo", action: action)
                        .keyboardShortcut("v", modifiers: .command)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                appIsActive = true
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                appIsActive = false
            }
            // A copy made in another app arrives with no notification: in Split
            // View this app stays active, so neither one above fires. The change
            // count is a plain integer read and raises no paste prompt. iPad
            // only (the iPhone has no Split View) and only while active.
            .task(id: appIsActive) {
                guard appIsActive, UIDevice.current.userInterfaceIdiom == .pad else { return }
                var seen = UIPasteboard.general.changeCount
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let count = UIPasteboard.general.changeCount
                    if count != seen {
                        seen = count
                        refresh()
                    }
                }
            }
    }

    /// The `has` checks read the clipboard's types, not its contents, so they
    /// don't raise the paste-permission prompt.
    private func refresh() {
        let board = UIPasteboard.general
        clipboardHoldsOnlyImage = board.hasImages && !board.hasStrings && !board.hasURLs
    }
}
#endif
