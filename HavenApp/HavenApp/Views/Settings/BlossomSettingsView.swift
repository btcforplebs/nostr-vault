import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct BlossomSettingsView: View {
    /// Pushed on a navigation stack: a Back button that asks before leaving
    /// replaces the system one while there are unsaved changes. Sheets and
    /// Settings sidebars ask through `MediaServersLeaveGuard` instead.
    var pushed = true
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var mirrorService = MirrorService.shared
    @ObservedObject private var waitingPosts = MediaPostQueue.shared

    @State private var newMirrorURL = ""
    /// Every add and remove is a draft: nothing is stored or published until Save.
    @State private var draft = MediaServersDraft(mirrors: ConfigService.shared.config.blossomMirrors)
    @ObservedObject private var leaveGuard = MediaServersLeaveGuard.shared
    @Environment(\.dismiss) private var dismiss
    
    private func waitingLine(_ post: QueuedMediaPost) -> String {
        if let line = post.refusalLine { return line }
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
                                Text("Desktop vault sync")
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
                            Text("No desktop vault sync set up")
                                .font(.appSubheadline.bold())
                                .foregroundColor(.secondary)
                            Text("Add it under Desktop vault sync and it's used here automatically.")
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
                let mirrors = draft.mirrors
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
                            Button(action: { draft.removeMirror(url) }) {
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

            SuggestedMediaServersSection(servers: draft.mirrors) { url in
                addMirror(url)
            }

            MeshMediaServersSection(draft: $draft)
            
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
        .safeAreaInset(edge: .bottom) { saveBar }
        // Leaving with unsaved changes asks first: nothing was stored or published.
        .navigationBarBackButtonHidden(pushed && draft.hasChanges)
        .interactiveDismissDisabled(draft.hasChanges)
        .toolbar {
            if pushed && draft.hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        leaveGuard.requestLeave { dismiss() }
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .confirmationDialog("Save \(MediaServersDraft.changesLabel(draft.changeCount))?",
                            isPresented: Binding(get: { leaveGuard.pendingLeave != nil },
                                                 set: { if !$0 { leaveGuard.cancel() } }),
                            titleVisibility: .visible) {
            Button("Save") {
                save()
                leaveGuard.proceed()
            }
            Button("Discard", role: .destructive) {
                draft.discard()
                leaveGuard.proceed()
            }
            Button("Keep Editing", role: .cancel) { leaveGuard.cancel() }
        } message: {
            Text("Your media server list hasn't been saved or published.")
        }
        .onChange(of: configService.config.blossomMirrors) { _, saved in
            draft.savedMirrorsChanged(saved)
        }
        .onChange(of: draft.hasChanges, initial: true) { _, changed in
            leaveGuard.hasChanges = changed
        }
        // Gone some way nothing could ask about (the window closed): nothing
        // was stored or published, and the next screen is not held up.
        .onDisappear {
            leaveGuard.cancel()
            leaveGuard.hasChanges = false
        }
    }

    private var saveBar: some View {
        let changes = draft.changeCount
        return VStack(spacing: 6) {
            Button(action: save) {
                Text(changes == 0 ? "Save" : "Save (\(MediaServersDraft.changesLabel(changes)))")
                    .font(.appBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.havenPurple)
            .disabled(changes == 0)
            Text("Only Save publishes your media server list.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Stores the typed servers and publishes the list once, with the mesh
    /// vaults added and removed on this screen.
    private func save() {
        let plan = draft.savePlan
        guard draft.hasChanges else { return }
        if plan.mirrorsChanged {
            configService.config.blossomMirrors = plan.mirrors
            // A published list older than this edit is not adopted over it.
            configService.config.blossomMirrorsUpdatedAt = Int64(Date().timeIntervalSince1970)
            configService.save()
        }
        NostrService.shared.publishServerList(meshAdd: plan.meshAdd, meshRemove: plan.meshRemove)
        draft.didSave()
        // The publish can change nothing (relays didn't answer): show the
        // published list again after a while rather than a tap that didn't land.
        if !plan.meshAdd.isEmpty || !plan.meshRemove.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(20))
                draft.publishedListChanged()
            }
        }
    }
    
    private func addMirror(_ typed: String) {
        // A tapped suggestion leaves a half-typed address alone.
        if draft.addMirror(typed), typed == newMirrorURL { newMirrorURL = "" }
    }
}
