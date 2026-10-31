import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct BlossomSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var mirrorService = MirrorService.shared
    @ObservedObject private var waitingPosts = MediaPostQueue.shared

    @State private var newMirrorURL = ""
    
    private func waitingLine(_ post: QueuedMediaPost) -> String {
        if let status = post.refusedStatus {
            return "Your media servers refused this file (HTTP \(status)). Change servers below, then tap Try sending now."
        }
        if post.needsUser {
            return "Stopped trying after \(post.attempts) tries. Tap Try sending now."
        }
        let since = "Waiting for a media server since \(post.createdAt.formatted(date: .abbreviated, time: .shortened))"
        guard post.attempts > 0, let next = post.nextAttempt else { return since }
        return since + ". Next try \(next.formatted(date: .omitted, time: .shortened))."
    }

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
                                Text(waitingLine(post))
                                    .font(.appCaption)
                                    .foregroundColor(post.needsUser ? .orange : .secondary)
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
                        waitingPosts.sendNow()
                    }
                } header: {
                    Text("Waiting to send")
                } footer: {
                    Text("The photos are saved on this device. These posts try again by themselves, less often each time, and stop after a while so they don't use up your data.")
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
                                Text("Home vault sync")
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
                            Text("No home vault sync set up")
                                .font(.appSubheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Add it under Home vault sync and it's used here automatically.")
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
                    Text("No other media servers added.")
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
                                configService.config.blossomMirrorsUpdatedAt = Int64(Date().timeIntervalSince1970)
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
                            addMirror(newMirrorURL)
                        }
                    
                    Button(action: { addMirror(newMirrorURL) }) {
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

            SuggestedMediaServersSection(servers: configService.config.blossomMirrors) { url in
                addMirror(url)
            }
            
            // Section 3: Media Sync & Mirroring
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mirror from Servers")
                            .font(.appBody)
                            .foregroundColor(.white)
                        Text("Download your media from your media servers into your vault")
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

            // Section 4: FIPS. Your own mesh (address, devices, sharing)
            // lives on the FIPS Mesh page; this is about other people's servers.
            #if os(macOS)
            Section {
                FipsMeshLinkRow()
            } header: {
                Text("Mesh")
            } footer: {
                Text("Your mesh address and what you share on the mesh are under Mesh.")
            }
            #else
            Section {
                Text("To load media from a .fips server, turn on the mesh under Mesh, then add the server's .fips address under Other Servers above.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                FipsMeshLinkRow()
            } header: {
                Text("Mesh")
            }
            #endif
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
    private func addMirror(_ typed: String) {
        var trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !trimmed.lowercased().hasPrefix("https://") && !trimmed.lowercased().hasPrefix("http://") {
                trimmed = "https://" + trimmed
            }
            while trimmed.hasSuffix("/") {
                trimmed = String(trimmed.dropLast())
            }
            if !configService.config.blossomMirrors.contains(trimmed) {
                configService.config.blossomMirrors.append(trimmed)
                // A published list older than this edit is not adopted over it.
                configService.config.blossomMirrorsUpdatedAt = Int64(Date().timeIntervalSince1970)
                configService.save()
                NostrService.shared.publishServerList()
                // A tapped suggestion leaves a half-typed address alone.
                if typed == newMirrorURL { newMirrorURL = "" }
            }
        }
    }
}
