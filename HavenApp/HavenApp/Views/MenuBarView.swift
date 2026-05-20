import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @ObservedObject private var feedService = FeedService.shared
    @State private var selectedTab: Tab = .feed
    #if os(macOS)
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    #endif
    var isPoppedOut: Bool = false
    
    @State private var inactivityTask: Task<Void, Never>?
    @State private var statusPulse = false
    @State private var showingOwnProfile = false
    
    enum Tab {
        case feed
        case search
        case relay
    }
    
    var body: some View {
        ZStack {
            // MARK: - Main Content
            VStack(spacing: 0) {
                // MARK: - Header
                HStack {
                    Label("Haven", systemImage: "server.rack")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.havenPurple)
                    
                    Spacer()
                    
                    if relayManager.isBooting {
                        Text(relayManager.bootStatusMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                    
                    


                    Button(action: {
                        if relayManager.isRunning {
                            relayManager.stopRelay()
                        } else {
                            relayManager.startRelay(config: configService.config)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(relayManager.isBooting ? Color.yellow : (relayManager.isRunning ? Color.green : Color.red))
                                .frame(width: 8, height: 8)
                                .scaleEffect(relayManager.isRunning && !relayManager.isBooting && statusPulse ? 1.4 : 1.0)
                                .opacity(relayManager.isRunning && !relayManager.isBooting && statusPulse ? 0.5 : 1.0)
                                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: statusPulse)
                                .onAppear { statusPulse = true }
                                .onChange(of: relayManager.isRunning) { _, running in statusPulse = running }
                            Text(relayManager.isBooting ? "Booting Relay" : (relayManager.isRunning ? "Stop Relay" : "Start Relay"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(relayManager.isBooting ? Color.yellow.opacity(0.2) : Color.havenPurplePale)
                        .foregroundColor(relayManager.isBooting ? Color.orange : Color.primary)
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(relayManager.isBooting)
                }
                .padding()
                .background(Color.platformControlBackground)
                
                // MARK: - Tabs
                HStack(spacing: 8) {
                    Menu {
                        ForEach(FeedMode.allCases, id: \.self) { mode in
                            Button(action: {
                                selectedTab = .feed
                                feedService.switchMode(mode)
                            }) {
                                Label(mode.rawValue, systemImage: feedService.feedMode == mode ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: feedService.feedMode == .global ? "globe" : "list.bullet.rectangle.portrait")
                                .font(.system(size: 13, weight: .semibold))
                            Text(feedService.feedMode.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == .feed ? Color.havenPurple.opacity(0.2) : Color.clear)
                        .foregroundColor(selectedTab == .feed ? Color.havenPurple : .secondary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    TabButton(icon: "magnifyingglass", title: "Search", isSelected: selectedTab == .search) {
                        selectedTab = .search
                    }

                    TabButton(icon: "doc.text.image", title: "Relay", isSelected: selectedTab == .relay) {
                        selectedTab = .relay
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .background(Color.platformControlBackground)
                
                Divider()
                
                // MARK: - Content
                ZStack {
                    Color.platformControlBackground // Darker background
                        .ignoresSafeArea()
                    
                    switch selectedTab {
                    case .feed:
                        FeedView()
                            .transition(.opacity)
                    case .search:
                        SearchView()
                            .transition(.opacity)
                    case .relay:
                        ViewerView()
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
                
                Divider()
                
                // MARK: - Footer
                HStack(spacing: 20) {
                    // Profile button
                    let ownerPubkey = NostrService.shared.ownerHexPubkey
                    Button(action: { showingOwnProfile = true }) {
                        AvatarView(
                            url: NostrService.shared.profiles[ownerPubkey]?.pictureURL,
                            pubkey: ownerPubkey
                        )
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(Color.havenPurple.opacity(0.4), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("My Profile")
                    .sheet(isPresented: $showingOwnProfile) {
                        ProfileView(pubkey: ownerPubkey)
                            .environmentObject(NostrService.shared)
                            .environmentObject(ConfigService.shared)
                            .frame(minWidth: 400, minHeight: 500)
                    }

                    Button(action: {
                        #if os(macOS)
                        NSApp.activate(ignoringOtherApps: true)
                        if #available(macOS 14.0, *) {
                            openSettings()
                        } else {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }
                        #endif
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                    
                    if !isPoppedOut {
                        Button(action: {
                            #if os(macOS)
                            openWindow(id: "viewer-window")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                NSApp.activate(ignoringOtherApps: true)
                                for window in NSApp.windows {
                                    if window.title == "Haven" {
                                        window.makeKeyAndOrderFront(nil)
                                        window.level = .normal
                                    }
                                    
                                    if window.level.rawValue > NSWindow.Level.normal.rawValue && window.title.isEmpty {
                                        window.orderOut(nil)
                                    }
                                }
                            }
                            #endif
                        }) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Pop Out")
                    }
                    
                    Spacer()
                    
                    Button("Quit Haven") {
                        #if os(macOS)
                        NSApp.terminate(nil)
                        #endif
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))
                }
                .padding()
                .background(Color.platformControlBackground)
            }
            .disabled(relayManager.isImporting) // Disable interaction when importing
            
            // MARK: - Import Overlay
            if relayManager.isImporting {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        Text("Importing Notes")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        // Progress Bar Custom Style
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(relayManager.importStatusMessage)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(relayManager.importProgress * 100))%")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.white)
                            }
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.havenPurplePale)
                                        .frame(height: 6)
                                    
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            LinearGradient(
                                                gradient: Gradient(colors: [.havenPurple, .havenPurpleLight]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: geo.size.width * relayManager.importProgress, height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                        .frame(width: 300)
                        
                        Text("Please keep the app open.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.5))
                        
                        Divider()
                            .background(Color.white.opacity(0.2))
                        
                        if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Failed") || relayManager.importStatusMessage.contains("Complete") {
                            Button(action: {
                                relayManager.dismissImport()
                            }) {
                                Text("Close")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.havenPurple)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 200)
                        } else {
                            Button(action: {
                                relayManager.cancelImport()
                            }) {
                                Text("Cancel Import")
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                    .background(Color.platformControlBackground)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.3), radius: 20)
                }
                .transition(.opacity)
            }

            // MARK: - Critical Process Kill Alert Overlay
            if relayManager.showProcessKillAlert {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text("Startup Error")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text("A previous Haven process is still running. Run the following command in Terminal to stop it, then relaunch the app.")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("pkill -9 haven")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(6)

                        Button(action: {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("pkill -9 haven", forType: .string)
                            #else
                            UIPasteboard.general.string = "pkill -9 haven"
                            #endif
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }

                    Button(action: {
                        relayManager.showProcessKillAlert = false
                        relayManager.forceCleanAndRestart()
                    }) {
                        Text("Retry")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 140, height: 36)
                            .background(Color.orange)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(30)
                .frame(width: 400)
                .background(Color.black)
                .cornerRadius(16)
                .transition(.scale.combined(with: .opacity))
                .zIndex(100)
            }
        }
        #if os(macOS)
        .onAppear {
            FloatingArrowController.shared.dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            startInactivityTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            stopInactivityTimer()
        }
        #endif
        

    }
    
    private func startInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled {
                selectedTab = .feed
            }
        }
    }

    private func stopInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }
}

struct TabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.havenPurple : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SearchView

struct SearchView: View {
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var searchQuery: String = ""
    @State private var searchSource: SearchSource = .all
    @State private var searchResults: SearchResults = .empty
    @State private var isSearching = false
    @State private var showingNoteDetail: FeedNote?
    @State private var showingProfile: String?
    #if os(iOS)
    @FocusState private var searchFieldFocused: Bool
    #endif

    enum SearchSource {
        case all
        case havenRelay
        case network

        var label: String {
            switch self {
            case .all: return "All"
            case .havenRelay: return "Haven Relay"
            case .network: return "Network"
            }
        }
    }

    struct SearchResults {
        var users: [String: FeedProfile] = [:]
        var notes: [FeedNote] = []
        var links: [SearchLink] = []
        var hashtags: [String] = []

        static let empty = SearchResults()

        var isEmpty: Bool {
            users.isEmpty && notes.isEmpty && links.isEmpty && hashtags.isEmpty
        }
    }

    struct SearchLink {
        let url: String
        let title: String
        let noteId: String
    }

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea()

            VStack(spacing: 0) {
                // Search header
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.secondary)

                        TextField("Search users, notes, hashtags...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            #if os(iOS)
                            .focused($searchFieldFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFieldFocused = false }
                            #endif
                            .onChange(of: searchQuery) { _, query in
                                performSearch(query: query)
                            }

                        if !searchQuery.isEmpty {
                            Button(action: {
                                searchQuery = ""
                                #if os(iOS)
                                searchFieldFocused = false
                                #endif
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                    // Source filter
                    HStack(spacing: 8) {
                        ForEach([SearchSource.all, .havenRelay, .network], id: \.self) { source in
                            Button(action: { searchSource = source }) {
                                Text(source.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(searchSource == source ? .white : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(searchSource == source ? Color.havenPurple : Color.clear)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                .padding()
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))

                Divider()

                // Results
                if searchQuery.isEmpty {
                    emptyState
                } else if isSearching {
                    loadingState
                } else if searchResults.isEmpty {
                    noResultsState
                } else {
                    resultsContent
                }
            }
        }
        #if os(iOS)
        .onTapGesture {
            searchFieldFocused = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    searchFieldFocused = false
                }
                .foregroundColor(Color.havenPurple)
            }
        }
        #endif
        .sheet(item: Binding<IdentifiableString?>(
            get: { showingProfile.map { IdentifiableString(id: $0) } },
            set: { showingProfile = $0?.id }
        )) { profile in
            ProfileView(pubkey: profile.id)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.5))

                VStack(spacing: 8) {
                    Text("Start Searching")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("Search for users, notes, hashtags and links")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var loadingState: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
                .tint(Color.havenPurple)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No results found")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var resultsContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Users section
                if !searchResults.users.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Users")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.users.sorted(by: { $0.key < $1.key }), id: \.key) { pubkey, profile in
                                userRow(pubkey: pubkey, profile: profile)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Notes section
                if !searchResults.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.notes) { note in
                                FeedNoteRow(note: note, profile: nostrService.profiles[note.pubkey], showParent: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        showingNoteDetail = note
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Hashtags section
                if !searchResults.hashtags.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hashtags")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.hashtags, id: \.self) { hashtag in
                                hashtagRow(hashtag: hashtag)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Links section
                if !searchResults.links.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Links")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)

                        VStack(spacing: 8) {
                            ForEach(searchResults.links, id: \.url) { link in
                                linkRow(link: link)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private func userRow(pubkey: String, profile: FeedProfile) -> some View {
        Button(action: { showingProfile = pubkey }) {
            HStack(spacing: 12) {
                AvatarView(url: profile.pictureURL, pubkey: pubkey)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.bestName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(pubkey.prefix(16) + "...")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func hashtagRow(hashtag: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(hashtag)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.havenPurple)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func linkRow(link: SearchLink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(link.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .lineLimit(1)

            Text(link.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func performSearch(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = .empty
            return
        }

        isSearching = true
        let trimmedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)

        DispatchQueue.global(qos: .userInitiated).async {
            var results = SearchResults()

            for (pubkey, profile) in nostrService.profiles {
                if profile.bestName.lowercased().contains(trimmedQuery) ||
                   pubkey.lowercased().contains(trimmedQuery) ||
                   (profile.about?.lowercased().contains(trimmedQuery) ?? false) {
                    results.users[pubkey] = profile
                }
            }

            let relevantNotes = feedService.notes.filter { note in
                note.content.lowercased().contains(trimmedQuery)
            }
            results.notes = relevantNotes.prefix(20).map { $0 }

            var foundHashtags = Set<String>()
            for note in relevantNotes {
                let hashtags = extractHashtags(from: note.content)
                for tag in hashtags {
                    if tag.lowercased().contains(trimmedQuery) {
                        foundHashtags.insert(tag)
                    }
                }
            }
            results.hashtags = Array(foundHashtags).sorted()

            let urls = extractURLs(from: relevantNotes)
            results.links = urls.filter { $0.url.lowercased().contains(trimmedQuery) ||
                                          $0.title.lowercased().contains(trimmedQuery) }

            DispatchQueue.main.async {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    private func extractHashtags(from text: String) -> [String] {
        let pattern = "#\\w+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range]).dropFirst().lowercased()
        }
    }

    private func extractURLs(from notes: [FeedNote]) -> [SearchLink] {
        var links: [SearchLink] = []
        let urlPattern = "https?://[^\\s]+"

        guard let regex = try? NSRegularExpression(pattern: urlPattern) else { return [] }

        for note in notes {
            let matches = regex.matches(in: note.content, range: NSRange(note.content.startIndex..., in: note.content))
            for match in matches {
                guard let range = Range(match.range, in: note.content) else { continue }
                let url = String(note.content[range])
                links.append(SearchLink(url: url, title: url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), noteId: note.id))
            }
        }

        return links
    }
}
