import SwiftUI

// MARK: - Portal card
//
// The sheet for anything that is not a plain photo/video share (that one
// keeps ShareCard, unchanged). Reading → pick an action → its form → queued.

struct SharePortalCard: View {
    @ObservedObject var model: SharePortalModel

    var body: some View {
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
            if case .form = model.phase {
                Button { model.phase = .choosing } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
            }
            Image(systemName: "tray.and.arrow.up.fill").foregroundStyle(Color.accentColor)
            Text("Nostr Vault").font(.headline)
            Spacer()
            if canCancel { Button("Cancel") { model.cancel() } }
        }
    }

    private var canCancel: Bool {
        switch model.phase {
        case .reading, .choosing, .form: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        case .choosing:
            ShareActionList(input: model.input, actions: model.offered) { model.pick($0) }
        case .form(let action):
            switch action {
            case .highlight:
                HighlightShareForm(input: model.input, accounts: model.accounts, account: $model.account) { form in
                    model.queue(.highlight, form: form)
                }
            case .pay:
                PayShareForm(input: model.input) { model.queue(.pay, form: [:]) }
            case .dm:
                DMShareForm(input: model.input, account: model.account) { form in
                    model.queue(.dm, form: form)
                }
            default:
                EmptyView()
            }
        case .queueing:
            ProgressView("Adding…").frame(maxWidth: .infinity).padding(.vertical, 12)
        case .queued(let action):
            message(icon: "checkmark.circle.fill",
                    text: "\(action.title) is waiting in Nostr Vault. Open the app or tap the notification to review and post it.")
            Button("Done") { model.finish() }.frame(maxWidth: .infinity)
        case .failed:
            message(icon: "exclamationmark.triangle.fill", text: "Couldn't hand this to Nostr Vault.")
            Button("Done") { model.finish() }.frame(maxWidth: .infinity)
        }
    }

    private func message(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}
