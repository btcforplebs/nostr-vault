import SwiftUI

/// The checklist: everyone you follow who follows X, all checked; uncheck to
/// keep someone. One warning always, a second at 25 or more, then the
/// backup, then one new follow list, and Undo (NuclearUnfollowService).
struct NuclearUnfollowListView: View {
    let target: String
    let name: String
    let people: [String]
    let complete: Bool
    let followsTarget: Bool
    let onFinished: () -> Void

    @EnvironmentObject var nostrService: NostrService
    @State private var checked: Set<String>
    @State private var warning = 0
    @State private var stage: Stage = .choosing

    enum Stage: Equatable {
        case choosing
        case savingBackup
        case publishing
        case done(Int)
        case undoing
        case undone
        case failed(String)
    }
    @State private var backup: NostrEvent?

    init(target: String, name: String, people: [String], complete: Bool, followsTarget: Bool,
         onFinished: @escaping () -> Void) {
        self.target = target
        self.name = name
        self.people = people
        self.complete = complete
        self.followsTarget = followsTarget
        self.onFinished = onFinished
        _checked = State(initialValue: Set(people))
    }

    private var removing: Set<String> {
        NuclearUnfollowPlan.removal(checked: checked, target: target,
                                    follows: followsTarget ? [target] : [])
    }

    var body: some View {
        List {
            Section {
                if followsTarget {
                    Label("\(name) is unfollowed too.", systemImage: "person.fill.xmark")
                        .font(.appSystem(size: 13))
                }
                if !complete {
                    Label("Some relays didn't answer, so this list may be missing people.",
                          systemImage: "exclamationmark.triangle")
                        .font(.appSystem(size: 13))
                        .foregroundColor(.orange)
                }
            }
            Section("People you follow who follow \(name)") {
                if people.isEmpty { Text("None").foregroundColor(.secondary) }
                ForEach(people, id: \.self) { row($0) }
            }
            Section { status }
        }
        .navigationTitle("Show list")
        .disabled(stage != .choosing && !isFinal)
        .safeAreaInset(edge: .bottom) { actionBar }
        .alert(NuclearUnfollowPlan.confirmTitle(removing.count) + "?", isPresented: binding(1)) {
            Button("Cancel", role: .cancel) { warning = 0 }
            Button(NuclearUnfollowPlan.confirmTitle(removing.count), role: .destructive) {
                if NuclearUnfollowPlan.needsSecondWarning(removing.count) { warning = 2 } else { warning = 0; run() }
            }
        } message: {
            Text("A backup of your follow list is saved first, and you can undo this.")
        }
        .alert("Are you sure?", isPresented: binding(2)) {
            Button("Cancel", role: .cancel) { warning = 0 }
            Button(NuclearUnfollowPlan.confirmTitle(removing.count), role: .destructive) { warning = 0; run() }
        } message: {
            Text("That is \(removing.count) people at once. Their posts leave your feed and they leave your Web of Trust.")
        }
    }

    private var isFinal: Bool {
        switch stage { case .done, .undone, .failed: return true; default: return false }
    }

    private func binding(_ step: Int) -> Binding<Bool> {
        Binding(get: { warning == step }, set: { if !$0 && warning == step { warning = 0 } })
    }

    private func row(_ hex: String) -> some View {
        let profile = nostrService.profiles[hex]
        let on = checked.contains(hex)
        return Button {
            if on { checked.remove(hex) } else { checked.insert(hex) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 20))
                    .foregroundColor(on ? .red : .secondary)
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 30)
                Text(profile?.bestName ?? String(hex.prefix(8)) + "…")
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(on ? "Will be unfollowed. Tap to keep." : "Kept. Tap to unfollow.")
        .onAppear { nostrService.fetchMissingProfiles(for: [hex]) }
    }

    @ViewBuilder
    private var status: some View {
        switch stage {
        case .choosing: EmptyView()
        case .savingBackup: Label("Saving a backup of your follow list…", systemImage: "clock")
        case .publishing:
            Label("Backup saved ✓", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            Label("Publishing your new follow list…", systemImage: "clock")
        case .done(let n):
            Label("Backup saved ✓", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            Label(n == 1 ? "Unfollowed 1 person." : "Unfollowed \(n) people.", systemImage: "checkmark.circle.fill")
        case .undoing: Label("Putting your follow list back…", systemImage: "clock")
        case .undone: Label("Your follow list is back as it was.", systemImage: "arrow.uturn.backward.circle.fill")
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 8) {
            switch stage {
            case .failed where backup != nil:
                // Published, then Undo failed: Undo again, or leave it.
                Button { undo() } label: { wide("Undo") }.buttonStyle(.bordered)
                Button { onFinished() } label: { wide("Done") }.buttonStyle(.borderedProminent)
            case .choosing, .failed:
                Button { warning = 1 } label: { wide(NuclearUnfollowPlan.confirmTitle(removing.count)) }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(removing.isEmpty)
            case .done:
                if backup != nil {
                    Button { undo() } label: { wide("Undo") }.buttonStyle(.bordered)
                }
                Button { onFinished() } label: { wide("Done") }.buttonStyle(.borderedProminent)
            case .undone:
                Button { onFinished() } label: { wide("Done") }.buttonStyle(.borderedProminent)
            case .savingBackup, .publishing, .undoing:
                ProgressView()
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func wide(_ text: String) -> some View {
        Text(text).font(.appSystem(size: 15, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private func run() {
        let cut = removing
        stage = .savingBackup
        Task {
            let outcome = await NuclearUnfollowService.unfollow(cut) { stage = .publishing }
            switch outcome {
            case .done(let n, let kept):
                backup = kept
                stage = .done(n)
            case .unchanged: stage = .failed("No one in the list is in your follow list now. Nothing was changed.")
            case .refused(let why): stage = .failed(why)
            }
        }
    }

    private func undo() {
        guard let backup else { return }
        stage = .undoing
        Task {
            switch await NuclearUnfollowService.undo(to: backup) {
            case .done, .unchanged: stage = .undone
            case .refused(let why): stage = .failed("Undo didn't go through: \(why)")
            }
        }
    }
}
