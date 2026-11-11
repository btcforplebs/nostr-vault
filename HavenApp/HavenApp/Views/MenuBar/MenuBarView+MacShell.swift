import SwiftUI

#if os(macOS)

extension MenuBarView {
    /// The Mac main window. One layout from the two apps it sits between:
    ///
    /// - the 68 pt rail (iPad landscape and the web app), floating on glass;
    /// - the page at a reading width, as the web caps it;
    /// - an opened note in a "Thread" column beside the list (web), not a
    ///   sheet over it;
    /// - "Your space" on the right when no thread is open (iPad and web).
    ///
    /// Glass is the rail and the toolbar only. Pages and panels are content.
    var macShellLayout: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let threadOpen = !noteSelection.isEmpty && MacShellLayout.threadBeside(windowWidth: width)
            let showsSpace = MacShellLayout.showsSpace(
                windowWidth: width, wanted: macShowsSpace,
                threadOpen: threadOpen, pageAllows: Self.pageShowsSpace(selectedTab))

            ZStack(alignment: .leading) {
                MacGlassBackdrop()
                HStack(spacing: MacShellLayout.inset) {
                    MacRail(
                        configService: configService,
                        relayManager: relayManager,
                        selectedTab: $selectedTab,
                        settingsPaneRequest: $settingsPaneRequest,
                        onNewPost: { showingCompose = true }
                    )

                    mainContent
                        .frame(maxWidth: Self.pageReadsNarrow(selectedTab) ? MacShellLayout.readingWidth : .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: .infinity)

                    if threadOpen {
                        MacThreadPane(selection: noteSelection)
                            .frame(width: MacShellLayout.threadWidth(windowWidth: width))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if showsSpace {
                        MacSpaceColumn(
                            configService: configService,
                            relayManager: relayManager,
                            selectedTab: $selectedTab,
                            settingsPaneRequest: $settingsPaneRequest
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(MacShellLayout.inset)
            }
            .animation(Motion.panel, value: threadOpen)
            .animation(Motion.panel, value: showsSpace)
            .onAppear { macThreadBeside = MacShellLayout.threadBeside(windowWidth: width) }
            .onChange(of: MacShellLayout.threadBeside(windowWidth: width)) { _, beside in
                macThreadBeside = beside
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedTab == .relay {
                    Button {
                        if relayManager.isRunning {
                            relayManager.stopRelay {
                                relayManager.startRelay(config: configService.config)
                            }
                        } else {
                            relayManager.startRelay(config: configService.config)
                        }
                    } label: {
                        Label(relayManager.isRunning ? "Restart Vault" : "Start Vault",
                              systemImage: relayManager.isRunning ? "arrow.clockwise" : "play.fill")
                    }
                    .disabled(relayManager.isBooting)
                    .help(relayManager.isRunning ? "Restart Vault" : "Start Vault")
                }
                Button { macShowsSpace.toggle() } label: {
                    Label(macShowsSpace ? "Hide Your Space" : "Show Your Space", systemImage: "sidebar.trailing")
                }
                .help(macShowsSpace ? "Hide Your Space" : "Show Your Space")
            }
        }
        // What came in while the app was away, beside the Vault row.
        .overlay { ReturnPillLayer() }
        .onReceive(NotificationCenter.default.publisher(for: .havenOpenVault)) { _ in
            selectedTab = .notes
        }
    }

    /// Pages made of posts are read at `MacShellLayout.readingWidth`. Grids,
    /// the globe, the dashboard and Settings use the whole column, and so
    /// does the Vault: its six-tab bar is wider than the reading width.
    static func pageReadsNarrow(_ tab: Tab) -> Bool {
        switch tab {
        case .feed, .search, .profile: return true
        case .notes, .media, .relay, .settings, .wot: return false
        }
    }

    /// "Your space" stays off the pages it would only repeat (Relay) or
    /// squeeze (the media grid, Settings' own two columns, the globe).
    static func pageShowsSpace(_ tab: Tab) -> Bool {
        switch tab {
        case .feed, .search, .profile, .notes: return true
        case .media, .relay, .settings, .wot: return false
        }
    }
}

#endif
