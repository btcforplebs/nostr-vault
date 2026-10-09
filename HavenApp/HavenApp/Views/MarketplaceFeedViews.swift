import SwiftUI

/// One tile in the Marketplace grid. Square and photo-first: every listing
/// that reaches the grid has an image, and product photos are shot square
/// far more often than not, so `.fill` crops little.
struct MarketplaceCardView: View {
    let listing: MarketListing
    let profile: FeedProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let imageURL = listing.images.first {
                        RetryableAsyncImage(url: imageURL, contentMode: .fill, targetSize: CGSize(width: 600, height: 600))
                    } else {
                        MarketplaceImagePlaceholder()
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if listing.isAuction {
                        MarketplaceAuctionBadge()
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title)
                    .font(.appSystem(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(listing.priceLabel)
                    .font(.appSystem(size: 14, weight: .heavy))
                    .foregroundColor(.havenPurple)
                    .lineLimit(1)

                Text(profile?.bestName ?? "npub…" + String(listing.pubkey.suffix(6)))
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.platformSeparator, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listing.title), \(listing.priceLabel)\(listing.isAuction ? ", auction" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

extension MarketListing {
    /// A listing parsed from a quoted or fetched note; nil for any other kind,
    /// or a listing without a title and photo.
    init?(note: FeedNote) {
        guard MarketListing.kinds.contains(note.kind) else { return nil }
        self.init(id: note.id, pubkey: note.pubkey, kind: note.kind, content: note.content, createdAt: note.createdAt, tags: note.tags)
    }
}

/// A listing quoted inside a post: photo, title, price. Tapping it opens the
/// same sheet as the Marketplace grid, from wherever the post is.
struct MarketplaceListingEmbedView: View {
    let listing: MarketListing
    @EnvironmentObject var nostrService: NostrService
    @State private var showingSheet = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let url = listing.images.first {
                    RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 200, height: 200))
                } else {
                    MarketplaceImagePlaceholder()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(listing.isAuction ? "Auction" : "Listing")
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(.havenPurple.opacity(0.8))
                Text(listing.title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(listing.priceLabel)
                    .font(.appSystem(size: 13, weight: .heavy))
                    .foregroundColor(.havenPurple)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderStrong, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { showingSheet = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showingSheet) {
            MarketplaceListingSheet(listing: listing)
                .environmentObject(nostrService)
        }
    }
}

/// Category chips for the grid. `categories` only holds the ones that have
/// listings, so no chip ever leads to an empty grid.
struct MarketplaceCategoryBar: View {
    let categories: [MarketCategory]
    @Binding var selected: MarketCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: selected == nil) { selected = nil }
                ForEach(categories, id: \.self) { category in
                    chip(title: category.rawValue, isOn: selected == category) {
                        selected = (selected == category) ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? Color.havenPurple : Color.havenPurplePale)
                .foregroundColor(isOn ? .white : .havenPurple)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct MarketplaceImagePlaceholder: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color.havenPurplePale)
            Image(systemName: "bag")
                .font(.appSystem(size: 28))
                .foregroundColor(.havenPurple.opacity(0.7))
        }
    }
}

private struct MarketplaceAuctionBadge: View {
    var body: some View {
        Label("Auction", systemImage: "hammer.fill")
            .font(.appSystem(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.havenPurple)
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
}

/// A listing opened from the grid: photos, price, what and where, the
/// seller, the description, and where to buy it. Nostr Vault doesn't run a
/// checkout, so buying hands off to Plebeian Market, or the buyer messages
/// the seller. Shopstr was linked too until 2026-10-04, when Logen reported
/// it dead.
struct MarketplaceListingSheet: View {
    let listing: MarketListing
    var onOpenProfile: ((String) -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingEventInfo = false
    @State private var showingMessage = false
    @State private var photoIndex = 0

    private var profile: FeedProfile? { nostrService.profiles[listing.pubkey] }
    private var sellerName: String { profile?.bestName ?? "npub…" + String(listing.pubkey.suffix(6)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    photos

                    VStack(alignment: .leading, spacing: 18) {
                        header
                        seller
                        if !listing.summary.isEmpty {
                            Text(listing.summary)
                                .font(.appSystem(size: 15))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        buyButtons
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 28)
            }
            .navigationTitle(listing.isAuction ? "Auction" : "Listing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingEventInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Event Info")
                }
            }
            .sheet(isPresented: $showingMessage) {
                DMThreadView(counterpartyPubkey: listing.pubkey, initialMessage: messageToSeller)
                    .environmentObject(nostrService)
                    .environmentObject(ConfigService.shared)
            }
            .sheet(isPresented: $showingEventInfo) {
                EventBroadcastSheet(note: listing.note)
                    .environmentObject(nostrService)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 720)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private var photos: some View {
        let frame = Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
        if listing.images.count > 1 {
            #if os(iOS)
            TabView(selection: $photoIndex) {
                ForEach(Array(listing.images.enumerated()), id: \.offset) { index, url in
                    frame
                        .overlay { RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 1200, height: 1200)) }
                        .clipped()
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxHeight: 520)
            #else
            // No paging TabView on macOS: arrows step through the photos.
            frame
                .overlay { RetryableAsyncImage(url: listing.images[photoIndex], contentMode: .fill, targetSize: CGSize(width: 1200, height: 1200)).id(photoIndex) }
                .clipped()
                .overlay(alignment: .bottom) { macPhotoStepper }
            #endif
        } else {
            frame
                .overlay {
                    if let url = listing.images.first {
                        RetryableAsyncImage(url: url, contentMode: .fill, targetSize: CGSize(width: 1200, height: 1200))
                    } else {
                        MarketplaceImagePlaceholder()
                    }
                }
                .clipped()
                .frame(maxHeight: 520)
        }
    }

    #if os(macOS)
    private var macPhotoStepper: some View {
        HStack(spacing: 14) {
            Button { photoIndex = max(0, photoIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(photoIndex == 0)
            Text("\(photoIndex + 1) of \(listing.images.count)")
                .font(.appSystem(size: 12, weight: .semibold))
                .monospacedDigit()
            Button { photoIndex = min(listing.images.count - 1, photoIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(photoIndex == listing.images.count - 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
    #endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(listing.title)
                .font(.appSystem(size: 22, weight: .bold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(listing.priceLabel)
                    .font(.appSystem(size: 20, weight: .heavy))
                    .foregroundColor(.havenPurple)
                if listing.isAuction {
                    MarketplaceAuctionBadge()
                }
            }

            let details = [listing.category == .other ? nil : ("tag", listing.category.rawValue),
                           listing.location.map { ("mappin.and.ellipse", $0) }].compactMap { $0 }
            if !details.isEmpty {
                HStack(spacing: 14) {
                    ForEach(details, id: \.1) { icon, text in
                        Label(text, systemImage: icon)
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var seller: some View {
        Button {
            guard let onOpenProfile else { return }
            dismiss()
            onOpenProfile(listing.pubkey)
        } label: {
            HStack(spacing: 10) {
                AvatarView(url: profile?.pictureURL, pubkey: listing.pubkey, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sold by")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                    Text(sellerName)
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                Spacer()
                if onOpenProfile != nil {
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.controlBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onOpenProfile == nil)
    }

    @ViewBuilder
    private var buyButtons: some View {
        VStack(spacing: 10) {
            if let url = listing.plebeianURL {
                Button { openURL(url) } label: {
                    Label(listing.isAuction ? "Bid on Plebeian" : "Buy on Plebeian", systemImage: listing.isAuction ? "hammer" : "cart")
                        .font(.appSystem(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.havenPurple)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if listing.pubkey != nostrService.activeHexPubkey {
                Button { showingMessage = true } label: {
                    Label("Message seller", systemImage: "message")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundColor(.havenPurple)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.havenPurple, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    /// The opening line of a message to the seller: which listing, and its
    /// Plebeian link so the seller can see exactly what is being asked about.
    private var messageToSeller: String {
        let title = listing.title.isEmpty ? "your listing" : "“\(listing.title)”"
        var text = "Hi! I'm interested in \(title)."
        if let url = listing.plebeianURL { text += "\n\(url.absoluteString)" }
        return text
    }
}
