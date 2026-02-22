import SwiftUI

struct MenuBarView: View {
    @ObservedObject var configService: ConfigService
    @ObservedObject var relayManager: RelayProcessManager
    @State private var selectedTab: Tab = .dashboard
    #if os(macOS)
    @Environment(\.openSettings) var openSettings
    @Environment(\.openWindow) var openWindow
    #endif
    var isPoppedOut: Bool = false
    
    @State private var inactivityTask: Task<Void, Never>?
    @State private var statusPulse = false
    
    enum Tab {
        case dashboard
        case feed
        case viewer
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
                                .onChange(of: relayManager.isRunning) { running in statusPulse = running }
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
                }
                .padding()
                .background(Color.platformControlBackground)
                
                // MARK: - Tabs
                HStack(spacing: 8) {
                    TabButton(icon: "gauge", title: "Dashboard", isSelected: selectedTab == .dashboard) {
                        selectedTab = .dashboard
                    }
                    
                    TabButton(icon: "list.bullet.rectangle.portrait", title: "Feed", isSelected: selectedTab == .feed) {
                        selectedTab = .feed
                    }
                    
                    TabButton(icon: "doc.text.image", title: "Viewer", isSelected: selectedTab == .viewer) {
                        selectedTab = .viewer
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
                    case .dashboard:
                        DashboardView()
                            .transition(.opacity)
                    case .feed:
                        FeedView()
                            .transition(.opacity)
                    case .viewer:
                        ViewerView()
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: selectedTab)
                
                Divider()
                
                // MARK: - Footer
                HStack(spacing: 20) {
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
                selectedTab = .dashboard
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
