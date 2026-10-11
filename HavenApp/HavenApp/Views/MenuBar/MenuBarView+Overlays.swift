import SwiftUI

extension MenuBarView {
    @ViewBuilder
    var importOverlay: some View {
            // MARK: - Import Overlay
            if relayManager.isImporting {
                ZStack {
                    Color.black.opacity(0.8)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        Text("Importing Notes")
                            .font(.appTitle2.bold())
                            .foregroundColor(.white)
                        
                        // Progress Bar Custom Style
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(relayManager.importStatusMessage)
                                    .font(.appCaption)
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(relayManager.importProgress * 100))%")
                                    .font(.appCaption.monospaced())
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
                            .font(.appFootnote)
                            .foregroundColor(.white.opacity(0.5))
                        
                        Divider()
                            .background(Color.white.opacity(0.2))
                        
                        if relayManager.importProgress >= 1.0 || relayManager.importStatusMessage.contains("Failed") || relayManager.importStatusMessage.contains("Complete") {
                            Button(action: {
                                relayManager.dismissImport()
                            }) {
                                Text("Close")
                                    .font(.appSystem(size: 14, weight: .bold))
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
                                    .font(.appSystem(size: 13))
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
    }
}

extension MenuBarView {
    @ViewBuilder
    var processKillAlertOverlay: some View {
            // MARK: - Critical Process Kill Alert Overlay
            if relayManager.showProcessKillAlert {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appSystem(size: 48))
                        .foregroundColor(.orange)

                    VStack(spacing: 6) {
                        Text(String(localized: "relay.error.processKill.title"))
                            .font(.appTitle2.bold())
                            .foregroundColor(.white)

                        Text(String(localized: "relay.error.processKill.message"))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("pkill -9 haven")
                            .font(.appSystem(size: 14, weight: .medium, design: .monospaced))
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
                                .font(.appSystem(size: 14))
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
                        Text(String(localized: "relay.error.processKill.retry"))
                            .font(.appHeadline)
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
}
