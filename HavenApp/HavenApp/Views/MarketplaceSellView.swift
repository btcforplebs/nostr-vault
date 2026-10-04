import SwiftUI
import PhotosUI

/// Lists something for sale as a NIP-99 classified (kind 30402). There is no
/// checkout in the app: buyers find the listing here, on Shopstr or on
/// Plebeian, and arrange payment with the seller on the web.
struct MarketplaceSellView: View {
    var onDismiss: () -> Void
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var title = ""
    @State private var summary = ""
    @State private var description = ""
    @State private var price = ""
    @State private var currency = "SATS"
    @State private var category: MarketCategory = .other
    @State private var location = ""

    @State private var photoItems: [PhotosPickerItem] = []
    /// Picked photos, re-encoded as JPEG, in the order they were picked.
    @State private var photos: [PickedPhoto] = []

    @State private var isPosting = false
    @State private var status: String?
    @State private var error: String?

    private static let maxPhotos = 8

    struct PickedPhoto: Identifiable, Equatable {
        let id = UUID()
        let jpeg: Data
    }

    /// The draft as it stands, with placeholder URLs standing in for photos
    /// that are not uploaded yet, so `isComplete` can gate Publish.
    private var draftForValidation: ListingDraft {
        ListingDraft(title: title, summary: summary, description: description, price: price,
                     currency: currency, category: category, location: location,
                     imageURLs: photos.map { _ in URL(string: "https://pending.invalid")! })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    photoStrip
                } header: {
                    Text("Photos")
                } footer: {
                    Text("At least one. The first is the cover in the grid.")
                }

                Section {
                    TextField("What are you selling?", text: $title)
                        .font(.headline)
                    TextField("One-line summary (optional)", text: $summary, axis: .vertical)
                        .lineLimit(1...2)
                }

                Section("Price") {
                    HStack {
                        TextField(currency == "SATS" ? "21000" : "45.00", text: $price)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                        Picker("Currency", selection: $currency) {
                            ForEach(ListingDraft.currencies, id: \.self) { code in
                                Text(code == "SATS" ? "sats" : code).tag(code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Section {
                    Picker("Category", selection: $category) {
                        ForEach(MarketCategory.allCases, id: \.self) { c in
                            Text(c == .other ? "None" : c.rawValue).tag(c)
                        }
                    }
                    TextField("Location (optional)", text: $location)
                }

                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 140)
                } header: {
                    Text("Description")
                } footer: {
                    Text("Condition, size, shipping, and how buyers should pay or reach you. Buyers see this here, on Shopstr and on Plebeian.")
                }

                if let status {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(status).foregroundColor(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .disabled(isPosting)
            .navigationTitle("Sell something")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("List it") { publish() }
                        .fontWeight(.bold)
                        .disabled(!draftForValidation.isComplete || isPosting)
                }
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await addPhotos(items) }
        }
        .interactiveDismissDisabled(isPosting)
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 620, idealHeight: 760)
        #endif
    }

    // MARK: - Photos

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos) { photo in
                    thumbnail(photo)
                }
                if photos.count < Self.maxPhotos {
                    PhotosPicker(selection: $photoItems,
                                 maxSelectionCount: Self.maxPhotos - photos.count,
                                 matching: .images) {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                                .font(.appSystem(size: 22))
                            Text(photos.isEmpty ? "Add photos" : "Add")
                                .font(.appSystem(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.havenPurple)
                        .frame(width: 88, height: 88)
                        .background(Color.havenPurplePale)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func thumbnail(_ photo: PickedPhoto) -> some View {
        Group {
            if let image = Self.image(from: photo.jpeg) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.havenPurplePale
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                photos.removeAll { $0.id == photo.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("Remove photo")
        }
        .overlay(alignment: .bottomLeading) {
            if photo == photos.first {
                Text("Cover")
                    .font(.appSystem(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.havenPurple)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                    .padding(5)
            }
        }
    }

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            // HEIC from iPhones doesn't show in browsers; the cover encoder
            // also strips location data and caps the size.
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = LongFormComposeView.coverJPEG(from: data) {
                if photos.count < Self.maxPhotos { photos.append(PickedPhoto(jpeg: jpeg)) }
            } else {
                error = "Couldn't read one of those photos."
            }
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    // MARK: - Publishing

    private func publish() {
        isPosting = true
        error = nil
        let lock = ModePostPublisher.lockAccount(configService: configService)
        let toUpload = photos
        Task {
            do {
                var urls: [URL] = []
                for (index, photo) in toUpload.enumerated() {
                    status = toUpload.count == 1 ? "Uploading photo…" : "Uploading photo \(index + 1) of \(toUpload.count)…"
                    let blob = try await ModePostPublisher.upload(
                        data: photo.jpeg, mimeType: "image/jpeg",
                        configService: configService, nostrService: nostrService)
                    urls.append(blob.url)
                }
                status = "Publishing…"
                let draft = ListingDraft(title: title, summary: summary, description: description,
                                         price: price, currency: currency, category: category,
                                         location: location, imageURLs: urls)
                // The marketplace relays too: they are where the grid, Shopstr
                // and Plebeian look, and the owner's relays rarely are.
                try await ModePostPublisher.publish(
                    kind: MarketListing.classifiedKind, content: draft.content(),
                    tags: draft.tags(publishedAt: Int(Date().timeIntervalSince1970)),
                    extraRelays: MarketplaceFeedService.relayStrings,
                    nostrService: nostrService,
                    lockedTo: lock)
                MarketplaceFeedService.shared.refresh()
                status = nil
                isPosting = false
                onDismiss()
            } catch {
                status = nil
                isPosting = false
                self.error = error.localizedDescription
                ErrorNotificationManager.shared.show(error.localizedDescription)
            }
        }
    }
}
