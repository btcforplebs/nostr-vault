import SwiftUI

struct ProfileView: View {
    let pubkey: String
    @EnvironmentObject var nostrService: NostrService
    @StateObject private var feedService = FeedService.shared
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.havenPurple)
                }
                .padding()
                Spacer()
            }
            
            let profile = nostrService.profiles[pubkey]
            if let profile = profile {
                AvatarView(url: profile.pictureURL, pubkey: pubkey)
                    .frame(width: 80, height: 80)
                Text(profile.bestName)
                    .font(.title2.bold())
                Text(shortKey(pubkey))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ProgressView()
                    .onAppear {
                        nostrService.fetchMissingProfiles(for: [pubkey])
                    }
            }
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(feedService.notes.filter { $0.pubkey == pubkey }) { note in
                        let rowProfile = nostrService.profiles[pubkey]
                        FeedNoteRow(note: note, profile: rowProfile)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
    }
    
    private func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(8))
    }
}
