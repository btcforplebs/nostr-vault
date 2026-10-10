import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var statsService: StatsService
    @ObservedObject private var mirrorService = MirrorService.shared

    @State private var isPreparingImport = false
    @State private var statusAnimate = false
    @State private var didCopyAddress = false
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
    
    private var importProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Progress")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    Text(relayManager.importStatusMessage)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Text("\(Int(relayManager.importProgress * 100))%")
                    .font(.appSystem(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.havenPurple)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.havenPurple.opacity(0.1))
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.havenPurple, .havenPurpleLight]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * relayManager.importProgress)
                }
            }
            .frame(height: 8)
            
            if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Complete") {
                Button(action: {
                    relayManager.dismissImport()
                }) {
                    Text("Dismiss")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.havenPurple)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private var blossomImportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blossom Import")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(mirrorService.statusText.isEmpty ? "Complete" : mirrorService.statusText)
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if let prog = mirrorService.progress {
                    Text("\(prog.completed)/\(prog.total)")
                        .font(.appSystem(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.havenOnline)
                }
            }

            if let prog = mirrorService.progress, prog.total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.havenOnline.opacity(0.1))

                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [.havenOnline, .havenOnline.opacity(0.7)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * (Double(prog.completed) / Double(prog.total)))
                    }
                }
                .frame(height: 8)
            }

            // Scrollable log view
            if !mirrorService.logEntries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(mirrorService.logEntries) { entry in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(entry.timestamp, style: .time)
                                        .font(.appSystem(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .frame(width: 55, alignment: .leading)

                                    Text(entry.level)
                                        .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(blossomLogColor(entry.level))
                                        .frame(width: 35, alignment: .leading)

                                    Text(entry.message)
                                        .font(.appSystem(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(entry.id)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.platformTertiaryGroupedBackground)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.havenOnline.opacity(0.12), lineWidth: 0.5)
                    )
                    .onChange(of: mirrorService.logEntries.count) { _, _ in
                        if let lastId = mirrorService.logEntries.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if mirrorService.state == .complete {
                Button(action: {
                    mirrorService.state = .idle
                    mirrorService.logEntries = []
                }) {
                    Text("Dismiss")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.havenOnline.opacity(0.8))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.platformSecondaryGroupedBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.havenOnline.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func blossomLogColor(_ level: String) -> Color { .logLevel(level) }

    // MARK: - Status header

    private var statusColor: Color {
        if relayManager.isBooting { return .yellow }
        guard relayManager.isRunning else { return .red }
        return relayManager.isWotSyncing ? .orange : .havenOnline
    }

    private var statusTitle: String {
        if relayManager.isBooting { return "BOOTING" }
        guard relayManager.isRunning else { return "OFFLINE" }
        // The dot has always turned orange during a web-of-trust sync, but the
        // label said ONLINE in both branches — an unexplained colour change.
        return relayManager.isWotSyncing ? "SYNCING" : "ONLINE"
    }

    /// Drives the halo and the expanding ring. `Motion.ambientPulse` is `nil`
    /// under Reduce Motion, so the guard sits on the assignment too, or the
    /// halo is stranded mid-pulse. The loop is attached to the indicator with
    /// `.animation(_:value:)`, not `withAnimation`: this runs from `onAppear`
    /// while the dashboard sheet is presenting, and a repeat-forever
    /// transaction there also caught the sheet's Done button, which then
    /// pulsed for as long as the sheet was open.
    private func syncStatusPulse() {
        statusAnimate = (relayManager.isRunning || relayManager.isBooting)
            && Motion.ambientPulse != nil
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 24, height: 24)
                .scaleEffect(statusAnimate ? 1.3 : 1.0)

            Circle()
                .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .scaleEffect(statusAnimate ? 1.5 : 1.0)
                .opacity(statusAnimate ? 0.0 : 1.0)

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.8), radius: 4)
        }
        .animation(statusAnimate ? Motion.ambientPulse : Motion.fade, value: statusAnimate)
        .accessibilityHidden(true)
    }

    private func uptimeText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func liveMetaText(now: Date) -> String {
        var parts: [String] = []
        if let start = relayManager.startDate {
            parts.append("up \(uptimeText(since: start, now: now))")
        }
        let count = relayManager.activeConnections
        parts.append(count == 1 ? "1 connection" : "\(count) connections")
        return parts.joined(separator: " · ")
    }

    private func copyRelayAddress() {
        let address = configService.config.nostrURL
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #else
        UIPasteboard.general.string = address
        #endif
        withAnimation(Motion.control) { didCopyAddress = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.control) { didCopyAddress = false }
        }
    }

    /// The address the relay is actually reachable on. It lives in
    /// `config.relayURL` / `config.relayPort` and used to appear nowhere on the
    /// tab named after the relay — "Open Browser" was the only way to find it.
    @ViewBuilder
    private func relayAddressRow(showsMeta: Bool) -> some View {
        if relayManager.isBooting && !relayManager.bootStatusMessage.isEmpty {
            Text(relayManager.bootStatusMessage)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 10) {
                Button(action: copyRelayAddress) {
                    HStack(spacing: 5) {
                        Text(configService.config.nostrURL)
                            .font(.appSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                            .font(.appSystem(size: 9, weight: .semibold))
                            .foregroundColor(didCopyAddress ? .havenOnline : .secondary.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(didCopyAddress ? "Copied" : "Copy the relay address")
                #endif
                .accessibilityLabel(Text("Relay address"))
                .accessibilityValue(Text(configService.config.nostrURL))
                .accessibilityHint(Text("Copies the address to the clipboard"))
                .tutorialAnchor(TutorialContent.relayAddress)

                if showsMeta {
                    liveMeta
                }
            }
        }
    }

    @ViewBuilder
    private var liveMeta: some View {
        if relayManager.isRunning {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(liveMetaText(now: context.date))
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private var relayControls: some View {
        HStack(spacing: 8) {
            // Stop was reachable from Settings and the menu bar but not from the
            // screen named after the relay.
            if relayManager.isRunning {
                Button {
                    relayManager.stopRelay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.appSystem(size: 11, weight: .bold))
                        Text("Stop")
                            .font(.appSystem(size: 12, weight: .bold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.platformCardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.platformCardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(relayManager.isBooting)
                .accessibilityLabel(Text("Stop relay"))
            }

            Button {
                if relayManager.isRunning {
                    relayManager.stopRelay {
                        relayManager.startRelay(config: configService.config)
                    }
                } else {
                    relayManager.startRelay(config: configService.config)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: relayManager.isRunning ? "arrow.clockwise" : "play.fill")
                        .font(.appSystem(size: 11, weight: .bold))
                    Text(relayManager.isRunning ? "Restart" : "Start Relay")
                        .font(.appSystem(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleDark]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(8)
                .opacity(relayManager.isBooting ? 0.4 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(relayManager.isBooting)
            .accessibilityLabel(Text(relayManager.isRunning ? "Restart relay" : "Start relay"))
        }
    }

    /// `isCompact` stacks the controls under the status block. The one-row form
    /// needs roughly 420pt before the address starts truncating, which is wider
    /// than the 380pt sidebar rail.
    private func relayStatusHeader(isCompact: Bool) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    statusIndicator

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .accessibilityLabel(Text("Relay status"))
                            .accessibilityValue(Text(statusTitle))

                        relayAddressRow(showsMeta: !isCompact)

                        if isCompact {
                            liveMeta
                        }
                    }
                    .accessibilityElement(children: .contain)

                    Spacer(minLength: 12)

                    if !isCompact {
                        relayControls
                    }
                }

                if isCompact {
                    relayControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.platformCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                statusColor.opacity(0.35),
                                Color.platformCardBorder,
                                Color.white.opacity(0.02)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: statusColor.opacity(relayManager.isRunning && !relayManager.isBooting ? 0.08 : 0), radius: 10, x: 0, y: 4)
            .animation(Motion.toggle, value: relayManager.isRunning)
            .tutorialAnchor(TutorialContent.relayStatus)

            // Error recovery banner
            if relayManager.isLocked || relayManager.isPortConflict {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(relayManager.isPortConflict ? "Port \(configService.config.relayPort) is already in use" : "Database lock detected")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                    }

                    Text(relayManager.isPortConflict
                        ? "Another process is using the relay port. Close other Nostr Vault instances or restart your computer."
                        : "A previous session did not shut down cleanly. Clear locks to restart the relay.")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            relayManager.forceCleanAndRestart()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Force Restart")
                            }
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.havenPurple)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        if relayManager.isLocked {
                            Button {
                                relayManager.clearDatabaseLocks { [relayManager, configService] in
                                    Task { @MainActor in
                                        relayManager.startRelay(config: configService.config, isRetry: true)
                                    }
                                }
                            } label: {
                                Text("Clear Locks Only")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(.horizontal)
        .onAppear { syncStatusPulse() }
        .onChange(of: relayManager.isRunning) { _, _ in syncStatusPulse() }
        .onChange(of: relayManager.isBooting) { _, _ in syncStatusPulse() }
    }

}
