import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The globe on its own, from a post's WOT button. Finds the path the same way
/// Event Info's Trust Path card does, then shows the globe once it lands.
struct TrustWebSheet: View {
    let author: String
    @Environment(\.dismiss) private var dismiss

    @State private var path: TrustPath?

    init(author: String, path: TrustPath? = nil) {
        self.author = author
        _path = State(initialValue: path)
    }

    /// iPad: the globe gets the whole screen, where a sheet would box it in.
    static var opensFullScreen: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if let path {
                    TrustWebView(author: author, path: path)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(GlobeSpace())
                        .environment(\.colorScheme, .dark)
                        .navigationTitle("Web of Trust")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // A Mac sheet sizes to its content, and the globe has none of its own.
        .frame(minWidth: 820, minHeight: 600)
        #endif
        .task(id: author) {
            guard path == nil else { return }
            path = await TrustPathService.shared.path(for: author)
        }
    }
}

extension View {
    /// Opens the Web of Trust globe: full screen on iPad, a sheet elsewhere.
    func trustWebPresentation(isPresented: Binding<Bool>, author: String, path: TrustPath? = nil) -> some View {
        modifier(TrustWebPresentation(isPresented: isPresented, author: author, path: path))
    }
}

private struct TrustWebPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let author: String
    let path: TrustPath?

    func body(content: Content) -> some View {
        #if os(iOS)
        if TrustWebSheet.opensFullScreen {
            content.fullScreenCover(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        } else {
            content.sheet(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        }
        #else
        content.sheet(isPresented: $isPresented) { TrustWebSheet(author: author, path: path) }
        #endif
    }
}
