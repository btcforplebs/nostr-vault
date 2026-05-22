import SwiftUI

struct WelcomeWindowView: View {
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    
    var onDismiss: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Content Area
            VStack(spacing: 24) {
                // Icon
                Image(systemName: "server.rack")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.havenPurple, .havenPurpleLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(.top, 40)
                
                // Welcome Text
                VStack(spacing: 12) {
                    Text("Welcome to Nostr Vault")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("Your Personal Nostr Relay")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                // Info Card
                VStack(alignment: .leading, spacing: 16) {
                    #if os(macOS)
                    HStack(spacing: 12) {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 24))
                            .foregroundColor(.havenPurple)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nostr Vault lives in your menu bar")
                                .font(.system(size: 15, weight: .semibold))
                            
                            Text("Look for the")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            + Text(" ")
                            + Text(Image(systemName: "server.rack"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.havenPurple)
                            + Text(" icon in the top-right corner of your screen")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    #endif
                    
                    HStack(spacing: 12) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.havenPurple)
                            .frame(width: 32)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Click the icon to get started")
                                .font(.system(size: 15, weight: .semibold))
                            
                            Text("Set up your relay and start storing your Nostr notes locally")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.havenPurplePale.opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.havenPurple.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 32)
                
                Spacer()
                
                // Get Started Button
                Button(action: {
                    if let onDismiss = onDismiss {
                        onDismiss()
                    } else {
                        dismiss()
                    }
                }) {
                    HStack {
                        Text("Get Started")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "arrow.right")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.havenPurple, .havenPurpleLight],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 650)
        #endif
        .background(Color.platformWindowBackground)
        .onAppear {
            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Nostr Vault" }) {
                    window.makeKeyAndOrderFront(nil)
                    window.center()
                }
            }
            #endif
        }
    }
}

#Preview {
    WelcomeWindowView()
        .environmentObject(ConfigService())
}
