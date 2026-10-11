import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    @ObservedObject var mirrorService = MirrorService.shared

    @State private var isPreparingImport = false
    @State var statusAnimate = false
    @State var didCopyAddress = false
    @State private var showingKindBreakdown = false
    @State private var showingStorageBreakdown = false
    @State private var showingFullLogs = false
    @StateObject private var exporter = VaultExporter()
    @State private var showingShareSheet = false

    var isSidebar: Bool = false
    /// The Vault Dashboard: the relay's dashboard with the Blossom sections
    /// under it, one sheet for everything the Vault tab stores.
    var includesBlossom = false
    
    var body: some View {
        GeometryReader { geometry in
            #if os(macOS)
            if geometry.size.width < 750 {
                iOSConsoleLayout(geometry: geometry)
            } else {
                macOSConsoleLayout(geometry: geometry)
            }
            #else
            iOSConsoleLayout(geometry: geometry)
            #endif
        }
        .onAppear {
            statsService.refreshStats()
        }
        // The Vault in Your Pocket tutorial starts the first time the dashboard opens.
        .task(id: TutorialCenter.shared.revision) {
            TutorialCenter.shared.startIfEligible(.pocketRelay, account: NostrService.shared.activeHexPubkey)
        }
        .onChange(of: relayManager.isBooting) { _, isBooting in
            if !isBooting && relayManager.isRunning {
                statsService.refreshStats()
            }
        }
        #if os(iOS)
        .onChange(of: exporter.shareURL) { _, url in showingShareSheet = url != nil }
        .sheet(isPresented: $showingShareSheet, onDismiss: { exporter.shareURL = nil }) {
            if let url = exporter.shareURL {
                ShareSheet(activityItems: [url])
            }
        }
        #endif
        .onChange(of: relayManager.importCompleted) { _, completed in
            if completed {
                isPreparingImport = false
            }
        }
        .onChange(of: relayManager.isImporting) { _, isImporting in
            if isImporting {
                isPreparingImport = false
            }
        }
        .sheet(isPresented: $showingKindBreakdown) {
            EventKindBreakdownView()
                .environmentObject(statsService)
        }
        .sheet(isPresented: $showingStorageBreakdown) {
            // Blossom and media-cache detail now hang off the storage breakdown
            // rather than competing with it for a slot in the stat grid.
            StorageBreakdownView()
                .environmentObject(statsService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingFullLogs) {
            NavigationStack {
                RelayActivityWindow(logStore: relayManager.logStore) {
                    showingFullLogs = false
                }
                .environmentObject(relayManager)
                .environmentObject(configService)
            }
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 500)
            #endif
        }
    }

    #if os(macOS)
    private func macOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            relayStatusHeader(isCompact: false)
                .padding(.top, 8)
                .background(Color.platformWindowBackground)

            // Left rail carries status detail and controls; the console — the
            // thing you actually watch — gets the full remaining height instead
            // of a stats band pushing it down.
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    statsGrid

                    if relayManager.isImporting {
                        importProgressSection
                    }

                    if mirrorService.state != .idle {
                        blossomImportSection
                    }

                    if !relayManager.isImporting {
                        actionGrid
                    }

                    exportStatusView

                    Spacer(minLength: 0)
                }
                .frame(width: 380)

                relayConsole
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }

    /// The full-height console used by the wide layout: the plain-language
    /// relay activity. The raw log stays in Settings › Logs.
    private var relayConsole: some View {
        RelayActivityPanel(logStore: relayManager.logStore)
    }

    #endif

    private func iOSConsoleLayout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            if isSidebar {
                #if os(macOS)
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.havenPurple)
                    Text("Relay Dashboard")
                        .font(.appSystem(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .background(Color.platformWindowBackground)
                #endif
            }
            
            relayStatusHeader(isCompact: geometry.size.width < 480)
                .padding(.top, isSidebar ? 4 : 8)
                .background(Color.platformWindowBackground)
            
            ScrollView {
                VStack(spacing: 20) {
                    // MARK: - Compact Log Console
                    compactLogConsole

                    // MARK: - Statistics
                    fullStatsLayout
                    
                    // MARK: - Actions
                    Spacer(minLength: 8)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        if relayManager.isImporting {
                            importProgressSection
                        }

                        if mirrorService.state != .idle {
                            blossomImportSection
                        }

                        actionGrid
                            .padding(.horizontal)

                        exportStatusView
                            .padding(.horizontal)
                    }

                    if includesBlossom {
                        Divider()
                            .padding(.vertical, 4)
                        BlossomDashboardView(embedded: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                // iPad: two cards and a log console stretched across 13in read
                // as a blown-up phone. The column holds its measure and sits in
                // the middle of the pane instead.
                .readableWidthCap(820)
                .frame(minHeight: 350, maxHeight: .infinity, alignment: .top)
            }
            .refreshable {
                // A light top-up, never a full import. Pull-down used to run
                // Import Notes, which stops the relay and re-downloads
                // everything: one stray pull while scrolling (now easy, with
                // the bars folding on scroll) started it without anyone
                // asking, and it heated the phone. Import Notes is the button.
                guard relayManager.isRunning && !relayManager.isImporting else { return }
                RequestRelaySyncC()
                statsService.refreshStats()
            }
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    private var fullStatsLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal)

            statsGrid
                .padding(.horizontal)
        }
    }

    /// Two cards, not four. "Storage Used", "Blossom Storage" and "Media Cache"
    /// were three views of the same number with no hint which one mattered;
    /// the storage breakdown already splits the total three ways and now drills
    /// into the Blossom and cache detail from there.
    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return LazyVGrid(columns: columns, spacing: 8) {
            StatsCard(
                title: "Total Relay Events",
                value: "\(statsService.loadedEventsCount)",
                icon: "doc.text.fill",
                color: Color.havenPurple,
                isLoading: statsService.isUpdatingCount && statsService.loadedEventsCount == 0,
                action: { showingKindBreakdown = true }
            )
            StatsCard(
                title: "Storage Used",
                value: statsService.formattedStorageSize,
                icon: "internaldrive.fill",
                color: .blue,
                action: { showingStorageBreakdown = true }
            )
        }
    }

    /// Import and export are not peers: one pulls data in over the network for
    /// minutes, the others write a file. Exports read as tinted, not filled.
    private var actionGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]

        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 10) {
                ActionButton(icon: "arrow.down.circle", title: "Import Notes", isLoading: isPreparingImport || relayManager.isImporting) {
                    isPreparingImport = true
                    relayManager.importNotes(config: configService.config)
                }
                .disabled(isPreparingImport || relayManager.isImporting)

                ActionButton(icon: "photo.on.rectangle.angled", title: "Import Blossom", isLoading: mirrorService.state == .mirroring) {
                    mirrorService.runMirror(configService: configService, nostrService: nostrService)
                }
                .disabled(mirrorService.state == .mirroring)

                ActionButton(icon: "arrow.up.doc.fill", title: "Export JSONL", isLoading: exporter.running == .notes, emphasis: .secondary) {
                    exporter.export(.notes, relayManager: relayManager, config: configService.config)
                }
                .disabled(exporter.isBusy)

                ActionButton(icon: "photo.stack", title: "Export Blossom", isLoading: exporter.running == .media, emphasis: .secondary) {
                    exporter.export(.media, relayManager: relayManager, config: configService.config)
                }
                .disabled(exporter.isBusy)

                #if os(macOS)
                ActionButton(icon: "safari", title: "Open Browser", emphasis: .secondary) {
                    if let url = URL(string: configService.config.webURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif
            }

            // The wide layout left these live while the relay was stopped, and
            // neither layout said why they were unavailable.
            if !actionsAreEnabled {
                Text("Start the relay to import or export.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(!actionsAreEnabled)
    }

    private var actionsAreEnabled: Bool {
        relayManager.isRunning || relayManager.isImporting
    }

    /// Export outcomes were rendered in the stacked layout only, so a failed
    /// export on a wide macOS window produced no feedback at all.
    @ViewBuilder
    private var exportStatusView: some View {
        if !exporter.statusMessage.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: exporter.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.appSystem(size: 11))
                    .foregroundColor(exporter.statusIsError ? .orange : .havenOnline)
                Text(exporter.statusMessage)
                    .font(.appCaption)
                    .foregroundColor(exporter.statusIsError ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        }
    }

    private var compactLogConsole: some View {
        RelayActivityCard(logStore: relayManager.logStore) {
            showingFullLogs = true
        }
        .tutorialAnchor(TutorialContent.relayActivity)
        .padding(.horizontal)
    }


    private func geometryHeight(for width: CGFloat) -> CGFloat {
        var height: CGFloat = 350
        if width < 400 { height += 200 } // Stacked stats
        if width < 350 { height += 150 } // Stacked buttons
        return height
    }

}
