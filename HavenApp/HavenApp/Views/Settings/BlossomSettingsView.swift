import SwiftUI

struct BlossomSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var mirrorService = MirrorService.shared
    @ObservedObject private var waitingPosts = MediaPostQueue.shared

    @State private var newMirrorURL = ""
    #if os(macOS)
    @StateObject private var fipsDetection = FIPSDetectionService()
    #else
    @State private var isVPNActive = false
    #endif
    
    var body: some View {
        Form {
            // Posts whose media is on this device but on no outside server
            // yet. They send themselves; this is where the user can see them.
            if !waitingPosts.posts.isEmpty {
                Section {
                    ForEach(waitingPosts.posts) { post in
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.appSystem(size: 18))
                                .foregroundColor(.orange)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(post.body.isEmpty ? "Post with \(post.media.count) attachment(s)" : post.body)
                                    .font(.appSubheadline)
                                    .lineLimit(2)
                                Text("Waiting for a media server since \(post.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                waitingPosts.discard(id: post.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Try sending now") {
                        waitingPosts.retryAll(reason: "user")
                    }
                } header: {
                    Text("Waiting to send")
                } footer: {
                    Text("The photos are saved on this device. These posts send themselves as soon as a media server below answers.")
                }
            }

            // Section 1: Auto-Applied Blossom Server
            Section {
                let macHttps = configService.config.macRelayHttpsURL
                if !macHttps.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.appSystem(size: 18))
                            .foregroundColor(.havenOnline)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Mac Relay Sync Server")
                                    .font(.appSubheadline.bold())
                                    .foregroundColor(.white)
                                
                                Text("Active")
                                    .font(.appSystem(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.havenOnline.opacity(0.15))
                                    .foregroundColor(.havenOnline)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.havenOnline.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            Text(macHttps)
                                .font(.appSystem(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer.badge.warning")
                            .font(.appSystem(size: 18))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Mac Sync Relay Configured")
                                .font(.appSubheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Add it under Sync with Vault on Mac and it's used here automatically.")
                                .font(.appCaption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Your Mac")
            }
            
            // Section 2: Additional Blossom Servers (Mirrors)
            Section {
                let mirrors = configService.config.blossomMirrors
                if mirrors.isEmpty {
                    Text("No additional Blossom servers configured.")
                        .foregroundColor(.secondary)
                        .font(.appSubheadline)
                        .padding(.vertical, 4)
                } else {
                    ForEach(mirrors, id: \.self) { url in
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.appSystem(size: 14))
                                .foregroundColor(.havenPurple)
                            Text(url)
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: {
                                configService.config.blossomMirrors.removeAll(where: { $0 == url })
                                configService.save()
                                NostrService.shared.publishServerList()
                            }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                // Add mirror input
                HStack(spacing: 8) {
                    TextField("https://blossom.example.com", text: $newMirrorURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit {
                            addMirror()
                        }
                    
                    Button(action: addMirror) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.havenOnline)
                            .font(.appTitle3)
                    }
                    .buttonStyle(.plain)
                    .disabled(newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 4)
            } header: {
                Text("Other Servers").settingInfo(.shareMediaServers)
            }
            
            // Section 3: Media Sync & Mirroring
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mirror from Servers")
                            .font(.appBody)
                            .foregroundColor(.white)
                        Text("Download your media from external Blossom mirrors to local storage")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        mirrorService.runMirror(configService: configService, nostrService: NostrService.shared)
                    }) {
                        HStack(spacing: 6) {
                            if mirrorService.state == .mirroring {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            if let progress = mirrorService.progress, mirrorService.state == .mirroring {
                                Text("\(progress.completed)/\(progress.total)")
                            } else {
                                Text("Mirror Now")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.havenPurple.opacity(mirrorService.state == .mirroring ? 0.3 : 1.0))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(mirrorService.state == .mirroring || configService.config.activeBlossomMirrors.isEmpty)
                }
                
                Toggle(isOn: Binding(
                    get: { configService.config.autoMirrorMedia },
                    set: { newValue in
                        configService.config.autoMirrorMedia = newValue
                        configService.save()
                    }
                )) {
                    Text("Auto-Mirror Media")
                        .font(.appBody)
                        .settingInfo(.shareAutoMirror)
                }
            } header: {
                Text("Offline Copies")
            }

            // Section 4: FIPS
            #if os(macOS)
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(fipsStatusColor)
                        .frame(width: 8, height: 8)
                    Text(fipsStatusText)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }

                Toggle(isOn: Binding(
                    get: { configService.config.fipsPublishEnabled },
                    set: { newValue in
                        configService.config.fipsPublishEnabled = newValue
                        configService.save()
                        NostrService.shared.publishServerList(fipsDetectedNpub: fipsDetection.detectedNpub)
                    }
                )) {
                    Text("Publish .fips Address")
                        .font(.appBody)
                        .settingInfo(.shareFIPS)
                }

                if configService.config.fipsPublishEnabled {
                    Picker("Address Source", selection: Binding(
                        get: { configService.config.fipsAddressSource },
                        set: { newValue in
                            configService.config.fipsAddressSource = newValue
                            configService.save()
                            NostrService.shared.publishServerList(fipsDetectedNpub: fipsDetection.detectedNpub)
                        }
                    )) {
                        Text("My Nostr npub").tag("owner")
                        if fipsDetection.detectedNpub != nil {
                            Text("Detected (nostr-vpn)").tag("detected")
                        }
                        Text("Custom").tag("custom")
                    }

                    if configService.config.fipsAddressSource == "custom" {
                        TextField("npub1...", text: Binding(
                            get: { configService.config.fipsCustomNpub },
                            set: { newValue in
                                configService.config.fipsCustomNpub = newValue
                                configService.save()
                            }
                        ))
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .font(.appSystem(size: 12, design: .monospaced))
                    }

                    if let url = configService.config.fipsBlossomURL(detectedNpub: fipsDetection.detectedNpub) {
                        HStack {
                            Text(url)
                                .font(.appSystem(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.appSystem(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("A FIPS transport (e.g. nostr-vpn) must be running to make this address reachable.")
                        .font(.appCaption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            } header: {
                Text("FIPS")
            } footer: {
                Text("Expose your Blossom server over the FIPS overlay network. Clients with a FIPS transport can reach your media without a public IP or domain.")
            }
            #else
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isVPNActive ? Color.havenOnline : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isVPNActive ? "VPN active" : "No VPN detected")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Text("To access media from .fips servers, enable your FIPS VPN (e.g. nostr-vpn) and add the server's .fips address as an Additional Server above.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            } header: {
                Text("FIPS")
            }
            #endif
        }
        .groupedFormStyleCompat()
        #if os(macOS)
        .onAppear { fipsDetection.startPolling() }
        .onDisappear { fipsDetection.stopPolling() }
        #else
        .onAppear { isVPNActive = Self.checkVPNActive() }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    #if os(macOS)
    private var fipsStatusColor: Color {
        switch fipsDetection.status {
        case .running: return .havenOnline
        case .installed, .stale: return .yellow
        case .notInstalled: return .gray
        }
    }

    private var fipsStatusText: String {
        switch fipsDetection.status {
        case .running: return "FIPS transport active"
        case .stale: return "FIPS transport not responding"
        case .installed: return "FIPS transport installed but not running"
        case .notInstalled: return "No FIPS transport detected"
        }
    }
    #else
    static func checkVPNActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let addr = ptr {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
                return true
            }
            ptr = addr.pointee.ifa_next
        }
        return false
    }
    #endif
    
    private func addMirror() {
        var trimmed = newMirrorURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !trimmed.lowercased().hasPrefix("https://") && !trimmed.lowercased().hasPrefix("http://") {
                trimmed = "https://" + trimmed
            }
            while trimmed.hasSuffix("/") {
                trimmed = String(trimmed.dropLast())
            }
            if !configService.config.blossomMirrors.contains(trimmed) {
                configService.config.blossomMirrors.append(trimmed)
                configService.save()
                NostrService.shared.publishServerList()
                newMirrorURL = ""
            }
        }
    }
}
