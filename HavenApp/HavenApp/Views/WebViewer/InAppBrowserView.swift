import SwiftUI
import WebKit

/// The in-app browser: one screen for both kinds of link.
///
/// The badge says who sees what. **Mesh** (a `.fips` site): read over the
/// FIPS mesh with this device's mesh key, so the site never sees its IP.
/// **Web** (https): the internet, where the site sees the IP as in any
/// browser. iPhone and iPad show it full screen, the Mac in its own window.
/// Android: ui/screens/browser/InAppBrowserScreen.kt.
struct InAppBrowserView: View {
    @ObservedObject var model: InAppBrowserModel
    var onClose: () -> Void

    @State private var editing = ""
    @FocusState private var addressFocused: Bool
    @State private var explaining = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar
            ZStack {
                BrowserWebView(webView: model.webView)
                    .ignoresSafeArea(.container, edges: .bottom)
                if let failure = model.failure { failureCard(failure) }
            }
            .overlay(alignment: .top) { meshStatusPill }
            bottomBar
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: addressFocused) { _, focused in
            if focused { editing = model.address }
        }
        .alert("Leave the mesh?", isPresented: leaving, presenting: model.leavingMesh) { _ in
            Button("Open on the web", action: model.leaveMesh)
            Button("Stay on the mesh", role: .cancel) {}
        } message: { url in
            Text("\(url.host ?? url.absoluteString) is on the internet. It will see your IP address, as in any browser.")
        }
    }

    private var leaving: Binding<Bool> {
        Binding(get: { model.leavingMesh != nil }, set: { if !$0 { model.leavingMesh = nil } })
    }

    // MARK: Top: close, badge, address, reload

    private var topBar: some View {
        HStack(spacing: 10) {
            Button("Done", action: onClose)
                .fontWeight(.semibold)
                .keyboardShortcut(.cancelAction)
            badge
            addressField
            Button(action: model.reloadOrStop) {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(model.isLoading ? "Stop" : "Reload")
            .keyboardShortcut("r", modifiers: .command)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var badge: some View {
        Button { explaining = true } label: {
            Label(model.kind == .mesh ? "Mesh" : "Web",
                  systemImage: model.kind == .mesh ? "point.3.connected.trianglepath.dotted" : "globe")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(model.kind == .mesh ? Color.green : Color.orange)
                .background(Capsule().fill((model.kind == .mesh ? Color.green : Color.orange).opacity(0.16)))
        }
        .accessibilityHint("Explains who can see this page's visit")
        .popover(isPresented: $explaining) { explanation }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.kind == .mesh ? "Mesh page" : "Web page").font(.headline)
            Text(model.kind == .mesh
                 ? "Read over the FIPS mesh with this device's mesh key, not your Nostr key. The site never sees your IP address; the public seeds that route the mesh do."
                 : "Loaded from the internet. The site sees your IP address, as in any browser. Nothing you do here is kept after you close it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(idealWidth: 300)
        .presentationCompactAdaptation(.popover)
    }

    private var addressField: some View {
        TextField("Search or address", text: addressFocused ? $editing : .constant(model.address))
            .focused($addressFocused)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(1)
            .truncationMode(.middle)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .submitLabel(.go)
            #endif
            .onSubmit {
                if model.submit(editing) { addressFocused = false }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
            .accessibilityLabel("Address")
    }

    private var progressBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(model.kind == .mesh ? Color.green : Color.havenPurple)
                .frame(width: geo.size.width * (model.isLoading ? max(0.05, model.progress) : 0))
                .animation(.easeOut(duration: 0.2), value: model.progress)
        }
        .frame(height: 2)
        .opacity(model.isLoading ? 1 : 0)
    }

    // MARK: Bottom: back, forward, share, system browser

    private var bottomBar: some View {
        HStack {
            Button(action: model.goBack) { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack)
                .accessibilityLabel("Back")
            Spacer()
            Button(action: model.goForward) { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)
                .accessibilityLabel("Forward")
            Spacer()
            if let share = model.shareURL {
                ShareLink(item: share) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
            Spacer()
            Button { if let url = model.systemBrowserURL { InAppBrowser.openInSystemBrowser(url) } } label: {
                Image(systemName: "safari")
            }
            .disabled(model.systemBrowserURL == nil)
            .accessibilityLabel(systemBrowserLabel)
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private var systemBrowserLabel: String {
        #if os(iOS)
        "Open in Safari"
        #else
        "Open in Default Browser"
        #endif
    }

    // MARK: Overlays

    @ViewBuilder
    private var meshStatusPill: some View {
        if let status = model.meshStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.top, 12)
            .transition(.opacity)
        }
    }

    private func failureCard(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Can't open this page").font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try Again", action: model.reloadOrStop).buttonStyle(.borderedProminent)
                if let url = model.systemBrowserURL {
                    Button(systemBrowserLabel) { InAppBrowser.openInSystemBrowser(url) }.buttonStyle(.bordered)
                }
            }
        }
        .tint(Color.havenPurple)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#if os(iOS)
/// The model's web view in SwiftUI; it is made once and only placed here.
struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
