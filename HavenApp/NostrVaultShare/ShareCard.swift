import SwiftUI
import UIKit

// MARK: - Card

struct ShareCard: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        // Fills the sheet the system presents rather than floating a card in
        // it: the sheet is already the card, and follows light/dark itself.
        VStack(spacing: 16) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.and.arrow.up.fill")
                .foregroundStyle(Color.accentColor)
            Text("Nostr Vault").font(.headline)
            Spacer()
            if model.phase == .ready {
                Button("Cancel") { model.cancel() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ready:
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.add()
            } label: {
                Text("Add to the upload queue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.providers.isEmpty)
        case .adding:
            ProgressView("Adding…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        case .added:
            message(
                icon: "checkmark.circle.fill",
                text: "Added to the upload queue. Open Nostr Vault or tap the notification to finish."
            )
            Button("Done") { model.finish() }
                .frame(maxWidth: .infinity)
        case .failed(let added, let failed):
            message(
                icon: "exclamationmark.triangle.fill",
                text: added == 0
                    ? "Couldn't add \(failed == 1 ? "this item" : "these items")."
                    : "Added \(added). Couldn't add \(failed). Open Nostr Vault or tap the notification to finish."
            )
            Button("Done") { model.finish() }
                .frame(maxWidth: .infinity)
        }
    }

    private func message(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if model.photoCount > 0 { parts.append(model.photoCount == 1 ? "1 photo" : "\(model.photoCount) photos") }
        if model.videoCount > 0 { parts.append(model.videoCount == 1 ? "1 video" : "\(model.videoCount) videos") }
        return parts.isEmpty ? "Nothing here Nostr Vault can upload." : parts.joined(separator: ", ")
    }
}
