import SwiftUI
#if os(iOS)
import PhotosUI
#endif

// MARK: - ProfileEditView

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    let existing: FeedProfile
    /// Unsaved fields from an autosave that failed, by kind-0 key, laid over
    /// `existing` when the form opens so nothing typed is lost.
    var draft: [String: String]? = nil
    let onSave: (FeedProfile) -> Void
    /// iOS: called when the sheet goes away, swiped down or Done, with what
    /// the form showed when opened and what it holds now (by kind-0 key). The
    /// profile page publishes them; nil keeps the Cancel and Save buttons.
    var onAutosave: ((_ initial: [String: String], _ edited: [String: String]) -> Void)? = nil
    /// Discard was tapped: whatever `draft` held is thrown away too.
    var onDiscard: (() -> Void)? = nil
    /// Save (the Mac) closes the sheet once the profile is signed and sent;
    /// this runs if no relay then accepts it, with what the page showed
    /// before and what was typed.
    var onRefused: ((_ shownBefore: FeedProfile?, _ edited: [String: String]) -> Void)? = nil

    #if os(iOS)
    @State private var pickedPicture: PhotosPickerItem?
    @State private var pickedBanner: PhotosPickerItem?
    #endif
    @State private var uploading: UploadTarget?
    @State private var uploadError: String?
    enum UploadTarget { case picture, banner }

    @State private var displayName: String = ""
    @State private var name: String = ""
    @State private var about: String = ""
    @State private var pictureURL: String = ""
    @State private var bannerURL: String = ""
    @State private var nip05: String = ""
    @State private var lud16: String = ""
    @State private var website: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?
    /// What the form showed when opened, by kind-0 key: a save applies only fields changed from it.
    @State private var initialFields: [String: String] = [:]
    /// Set by Discard, so closing the sheet afterwards does not save.
    @State private var discarded = false

    private var hasChanges: Bool {
        ProfileEditView.hasChanges(initial: initialFields, edited: formFields())
    }

    var body: some View {
        platformContainer {
            VStack(spacing: 0) {
                editHeader

                ScrollView {
                    VStack(spacing: 0) {
                        bannerBlock

                        previewBlock

                        divider

                        fieldGroup(title: "IDENTITY") {
                            field(label: "Display Name", text: $displayName, placeholder: "Satoshi Nakamoto")
                            fieldDivider
                            field(label: "Username", text: $name, placeholder: "satoshi")
                            fieldDivider
                            field(label: "NIP-05", text: $nip05, placeholder: "you@domain.com", keyboardKind: .emailLike)
                        }

                        divider

                        fieldGroup(title: "BIO") {
                            multilineField(label: "About", text: $about, placeholder: "Tell people about yourself…")
                        }

                        divider

                        fieldGroup(title: "MEDIA") {
                            #if os(iOS)
                            photoPickers
                            fieldDivider
                            #endif
                            field(label: "Picture URL", text: $pictureURL, placeholder: "https://…", keyboardKind: .urlLike)
                            fieldDivider
                            field(label: "Banner URL", text: $bannerURL, placeholder: "https://…", keyboardKind: .urlLike)
                            fieldDivider
                            field(label: "Website", text: $website, placeholder: "yourdomain.com", keyboardKind: .urlLike)
                        }

                        divider

                        fieldGroup(title: "LIGHTNING") {
                            field(label: "Address (lud16)", text: $lud16, placeholder: "you@walletofsatoshi.com", keyboardKind: .emailLike)
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.appSystem(size: 12))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
        }
        .onAppear { loadFromExisting() }
        #if os(iOS)
        // Swiping away mid-upload would save without the new picture.
        .interactiveDismissDisabled(uploading != nil)
        .onChange(of: pickedPicture) { _, item in upload(item, to: .picture) }
        .onChange(of: pickedBanner) { _, item in upload(item, to: .banner) }
        #endif
        .onDisappear {
            guard let onAutosave, !discarded, hasChanges else { return }
            onAutosave(initialFields, formFields())
        }
    }

    @ViewBuilder
    private func platformContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        content()
            .frame(minWidth: 480, minHeight: 600)
            .background(Color.platformWindowBackground)
        #else
        content()
            .background(Color.platformWindowBackground.ignoresSafeArea())
        #endif
    }

    @ViewBuilder
    private var editHeader: some View {
        if onAutosave != nil {
            autosaveHeader
        } else {
            saveHeader
        }
    }

    /// No Save button: swiping the sheet down, or Done, saves. Discard is the
    /// way out without saving, and only does anything once a field changed.
    private var autosaveHeader: some View {
        HStack {
            Button("Discard") {
                discarded = true
                onDiscard?()
                performDismiss()
            }
            .foregroundColor(hasChanges && uploading == nil ? .red : .secondary)
            // Closing mid-upload would save without the new picture.
            .disabled(!hasChanges || uploading != nil)

            Spacer()

            VStack(spacing: 1) {
                Text("Edit Profile")
                    .font(.appSystem(size: 15, weight: .semibold))
                Text(hasChanges ? "Swipe down to save" : "Swipe down to close")
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .contentTransition(.opacity)
            }

            Spacer()

            Button(action: performDismiss) {
                Text("Done")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(uploading == nil ? .havenPurple : .secondary)
            }
            .disabled(uploading != nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Color.platformControlBackground)
        .overlay(
            Rectangle()
                .fill(Color.platformSeparator.opacity(0.5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var saveHeader: some View {
        HStack {
            Button("Cancel") { performDismiss() }
                .foregroundColor(.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Edit Profile")
                .font(.appSystem(size: 15, weight: .semibold))

            Spacer()

            Button(action: save) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.havenPurple)
                } else {
                    Text("Save")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.platformControlBackground)
        .overlay(
            Rectangle()
                .fill(Color.platformSeparator.opacity(0.5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// The Banner URL, previewed at the 3:1 shape profiles draw it in.
    /// Hidden until the field holds a URL.
    @ViewBuilder
    private var bannerBlock: some View {
        if let url = URL(string: bannerURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil {
            // The image sits in an overlay so a wide photo can't widen the row.
            Rectangle()
                .fill(Color.havenPurple.opacity(0.12))
                .aspectRatio(3, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(.havenPurple)
                    }
                }
                .clipped()
                .accessibilityLabel("Banner preview")
        }
    }

    private var previewBlock: some View {
        HStack(spacing: 14) {
            AvatarView(url: URL(string: pictureURL), pubkey: existing.pubkey, size: 56)
                .overlay(Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName.isEmpty ? (name.isEmpty ? "Unnamed" : name) : displayName)
                    .font(.appSystem(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !about.isEmpty {
                    Text(about)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.primary.opacity(0.75))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.5))
            .frame(height: 0.5)
            .padding(.vertical, 8)
    }

    private var fieldDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.appSystem(size: 10, weight: .heavy))
                .tracking(0.7)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            content()
        }
    }

    enum KeyboardKind { case `default`, urlLike, emailLike }

    @ViewBuilder
    private func field(label: String, text: Binding<String>, placeholder: String, keyboardKind: KeyboardKind = .default) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            TextField(placeholder, text: text)
                .font(.appSystem(size: 13))
                .textFieldStyle(.plain)
                .modifier(KeyboardModifier(kind: keyboardKind))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func multilineField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 8)
                        .padding(.leading, 6)
                }
                #if os(iOS)
                TextEditor(text: text)
                    .font(.appSystem(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                #else
                TextEditor(text: text)
                    .font(.appSystem(size: 13))
                    .frame(minHeight: 90)
                #endif
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadFromExisting() {
        displayName = existing.displayName ?? ""
        name = existing.name ?? ""
        about = existing.about ?? ""
        pictureURL = existing.pictureURL?.absoluteString ?? ""
        bannerURL = existing.bannerURL?.absoluteString ?? ""
        nip05 = existing.nip05 ?? ""
        lud16 = existing.lud16 ?? ""
        website = existing.website ?? ""
        initialFields = formFields()
        if let draft { applyFields(draft) }
    }

    private func applyFields(_ fields: [String: String]) {
        for (key, value) in fields {
            switch key {
            case ProfileMetadataMerge.displayName: displayName = value
            case ProfileMetadataMerge.name: name = value
            case ProfileMetadataMerge.about: about = value
            case ProfileMetadataMerge.picture: pictureURL = value
            case ProfileMetadataMerge.banner: bannerURL = value
            case ProfileMetadataMerge.nip05: nip05 = value
            case ProfileMetadataMerge.lud16: lud16 = value
            case ProfileMetadataMerge.website: website = value
            default: break
            }
        }
    }

    private func formFields() -> [String: String] {
        [
            ProfileMetadataMerge.displayName: displayName,
            ProfileMetadataMerge.name: name,
            ProfileMetadataMerge.about: about,
            ProfileMetadataMerge.picture: pictureURL,
            ProfileMetadataMerge.banner: bannerURL,
            ProfileMetadataMerge.nip05: nip05,
            ProfileMetadataMerge.lud16: lud16,
            ProfileMetadataMerge.website: website,
        ]
    }

    private func save() {
        errorMessage = nil
        isSaving = true
        let edited = formFields()
        let initial = initialFields
        let shownBefore = nostrService.profiles[existing.pubkey]
        let onRefused = onRefused

        Task {
            switch await ProfileEditView.publish(nostrService: nostrService, existing: existing,
                                                 initial: initial, edited: edited,
                                                 onRefused: { onRefused?(shownBefore, edited) }) {
            case .success(let updated):
                onSave(updated)
                isSaving = false
                performDismiss()
            case .failure(let failure):
                errorMessage = failure.message
                isSaving = false
            }
        }
    }

    struct SaveFailure: Error { let message: String }

    /// True when a field differs from what the form showed, ignoring the
    /// spaces and newlines a save trims anyway.
    static func hasChanges(initial: [String: String], edited: [String: String]) -> Bool {
        edited.contains { key, value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                != (initial[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `existing` with the changed fields applied, for showing an edit before
    /// the relays have it.
    static func preview(_ existing: FeedProfile, initial: [String: String], edited: [String: String]) -> FeedProfile {
        let shown = initial.filter { !$0.value.isEmpty }.mapValues { $0 as Any }
        return profile(existing, from: ProfileMetadataMerge.merge(base: shown, initial: initial, edited: edited))
    }

    /// Publishes the changed fields as a new kind 0 and returns the profile it
    /// describes. Success means signed and sent; `onRefused` runs later, on
    /// the main thread, if every relay then turns it down or never answers.
    static func publish(nostrService: NostrService, existing: FeedProfile,
                        initial: [String: String], edited: [String: String],
                        onRefused: (@MainActor () -> Void)? = nil) async -> Result<FeedProfile, SaveFailure> {
        // A kind 0 replaces the whole profile. Start from the newest one on
        // the relays so lud06 and every key this form doesn't show
        // survive; if it can't be fetched, publishing would wipe them, so
        // don't (same rule as the follow list).
        let pubkey = nostrService.activeHexPubkey
        let alsoAsk = (nostrService.outboxRelays[pubkey] ?? []) + (nostrService.relayLists[pubkey] ?? [])
        let lookup = await nostrService.lookupNewestReplaceable(kind: 0, for: pubkey, alsoAsk: alsoAsk)
        guard lookup.event != nil || lookup.confirmedNone else {
            return .failure(SaveFailure(message: "Couldn't load your current profile from the relays. Nothing was changed; try again."))
        }
        let merged = ProfileMetadataMerge.merge(base: ProfileMetadataMerge.parseContent(lookup.event?.content),
                                                initial: initial, edited: edited)
        guard let jsonStr = ProfileMetadataMerge.encode(merged) else {
            return .failure(SaveFailure(message: "Could not encode profile."))
        }

        // The tags go too: NIP-39 `i` identities and NIP-30 emoji set in
        // other clients would be dropped by an empty list.
        guard let signed = await nostrService.signEventAsync(kind: 0, content: jsonStr, tags: lookup.event?.tags ?? []) else {
            return .failure(SaveFailure(message: "Could not sign event. Check that your key is available."))
        }

        nostrService.postEvent(signed, onBroadcastOutcome: { outcome in
            guard outcome == .refused else { return }
            Task { @MainActor in onRefused?() }
        })

        var updated = profile(existing, from: merged)
        updated.lud06 = merged["lud06"] as? String
        updated.metadataCreatedAt = signed.created_at
        return .success(updated)
    }

    private static func profile(_ existing: FeedProfile, from merged: [String: Any]) -> FeedProfile {
        var updated = existing
        updated.name = merged[ProfileMetadataMerge.name] as? String
        updated.displayName = merged[ProfileMetadataMerge.displayName] as? String
        updated.about = merged[ProfileMetadataMerge.about] as? String
        updated.pictureURL = (merged[ProfileMetadataMerge.picture] as? String).flatMap { URL(string: $0) }
        updated.bannerURL = (merged[ProfileMetadataMerge.banner] as? String).flatMap { URL(string: $0) }
        updated.nip05 = merged[ProfileMetadataMerge.nip05] as? String
        updated.lud16 = merged[ProfileMetadataMerge.lud16] as? String
        updated.website = merged[ProfileMetadataMerge.website] as? String
        return updated
    }

    // MARK: - Photo upload

    #if os(iOS)
    /// Picture and banner from Photos, uploaded to your Blossom servers; the
    /// URL lands in the field below, the same as pasting one.
    private var photoPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                photoPicker("Picture", selection: $pickedPicture, target: .picture)
                photoPicker("Banner", selection: $pickedBanner, target: .banner)
            }
            if let uploadError {
                Text(uploadError)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func photoPicker(_ title: String, selection: Binding<PhotosPickerItem?>, target: UploadTarget) -> some View {
        let label = photoPickerLabel(title, busy: uploading == target)
        return PhotosPicker(selection: selection, matching: .images) { label }
            .buttonStyle(.plain)
            .disabled(uploading != nil)
            .accessibilityLabel("Choose \(title.lowercased()) from Photos")
    }

    private func photoPickerLabel(_ title: String, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().scaleEffect(0.7).tint(.havenPurple)
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.appSystem(size: 12, weight: .semibold))
            }
            Text(busy ? "Uploading…" : "Choose \(title.lowercased())")
                .font(.appSystem(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.havenPurple)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(Color.havenPurple.opacity(0.12))
        .cornerRadius(6)
    }

    private func upload(_ item: PhotosPickerItem?, to target: UploadTarget) {
        guard let item else { return }
        uploading = target
        uploadError = nil
        Task {
            defer {
                uploading = nil
                pickedPicture = nil
                pickedBanner = nil
            }
            do {
                guard let raw = try await item.loadTransferable(type: Data.self),
                      let jpeg = ProfileEditView.jpeg(raw, longEdge: target == .picture ? 1024 : 2400) else {
                    uploadError = "Couldn't read that photo."
                    return
                }
                let blob = try await ModePostPublisher.upload(data: jpeg, mimeType: "image/jpeg",
                                                              configService: configService, nostrService: nostrService)
                switch target {
                case .picture: pictureURL = blob.url.absoluteString
                case .banner: bannerURL = blob.url.absoluteString
                }
            } catch {
                uploadError = error.localizedDescription
            }
        }
    }

    /// A JPEG no longer than `longEdge` on its long side. Photos hands over
    /// HEIC at full camera size; a profile picture is shown at 72 points.
    private static func jpeg(_ data: Data, longEdge: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, longEdge / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.88)
    }
    #endif

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

private struct KeyboardModifier: ViewModifier {
    let kind: ProfileEditView.KeyboardKind

    func body(content: Content) -> some View {
        #if os(iOS)
        switch kind {
        case .urlLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
        case .emailLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled(true)
        case .default:
            content
        }
        #else
        content
        #endif
    }
}
