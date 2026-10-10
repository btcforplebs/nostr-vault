import SwiftUI

/// One confirmation treatment for every action that cannot be undone.
///
/// Six places in the app fired an irreversible action on a single click — two
/// of them spending money — and the two that did ask never said how much was
/// at stake. Rather than six bespoke alerts that each phrase the stakes
/// differently, every site funnels through this modifier, which fixes the
/// shape of the question:
///
/// - the **title** names the action, in the same words as the button that
///   opened it, so you can tell which control you actually hit;
/// - the **consequence** is one plain sentence about what you lose, and it
///   carries the amount whenever money moves;
/// - **Cancel is the default key action**, so Return and Escape both back out.
///   The destructive verb has to be chosen deliberately, with the pointer.
private struct DestructiveConfirmation: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let consequence: String
    let confirmTitle: String
    let cancelTitle: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            // Listed first and given the default key action so a stray Return
            // dismisses instead of confirming. `.cancel` already claims Escape.
            Button(cancelTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(confirmTitle, role: .destructive, action: action)
        } message: {
            Text(consequence)
        }
    }
}

/// The same treatment for a row action, where the confirmation has to name the
/// row it came from — which member, which token, how many sats.
private struct DestructiveItemConfirmation<Item: Identifiable>: ViewModifier {
    let title: String
    @Binding var item: Item?
    let consequence: (Item) -> String
    let confirmTitle: String
    let cancelTitle: String
    let action: (Item) -> Void

    /// `alert(_:isPresented:presenting:)` needs a `Bool` binding of its own;
    /// clearing it has to clear the item too, or the next row opens on the
    /// stale one.
    private var isPresented: Binding<Bool> {
        Binding(
            get: { item != nil },
            set: { if !$0 { item = nil } }
        )
    }

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented, presenting: item) { pending in
            Button(cancelTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button(confirmTitle, role: .destructive) { action(pending) }
        } message: { pending in
            Text(consequence(pending))
        }
    }
}

extension View {
    /// Ask before an action that cannot be undone.
    ///
    /// - Parameters:
    ///   - title: The action, in the same words as the button that opened this.
    ///   - isPresented: Set by that button.
    ///   - consequence: What is lost, in plain words. Name the amount when
    ///     money moves — a confirmation without the number is not one.
    ///   - confirmTitle: The destructive verb. Not "OK".
    ///   - action: Runs only on confirm.
    func confirmDestructive(
        _ title: String,
        isPresented: Binding<Bool>,
        consequence: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        action: @escaping () -> Void
    ) -> some View {
        modifier(DestructiveConfirmation(
            title: title,
            isPresented: isPresented,
            consequence: consequence,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            action: action
        ))
    }

    /// Ask before a row action that cannot be undone, naming the row.
    ///
    /// - Parameters:
    ///   - item: The pending row. Non-nil presents the alert; confirming or
    ///     cancelling clears it.
    ///   - consequence: Built from the row, so it can name the member or the
    ///     amount.
    func confirmDestructive<Item: Identifiable>(
        _ title: String,
        item: Binding<Item?>,
        consequence: @escaping (Item) -> String,
        confirmTitle: String,
        cancelTitle: String = "Cancel",
        action: @escaping (Item) -> Void
    ) -> some View {
        modifier(DestructiveItemConfirmation(
            title: title,
            item: item,
            consequence: consequence,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            action: action
        ))
    }
}

/// Which copies of a Blossom blob a media delete removes. The wording matches
/// Android's `DeleteBlobConfirmDialog` (MediaViewerScreen.kt), so both apps
/// ask the same question before deleting.
enum MediaDeleteScope: Identifiable {
    case mirrors
    case everywhere

    var id: Self { self }

    var title: String {
        switch self {
        case .mirrors: return "Delete from mirrors?"
        case .everywhere: return "Delete everywhere?"
        }
    }

    var message: String {
        switch self {
        case .mirrors:
            return "Removes this blob from all external Blossom mirrors. Your local copy is kept."
        case .everywhere:
            return "Permanently removes this blob from your local Blossom store and all external mirrors. This cannot be undone."
        }
    }

    var confirmTitle: String {
        switch self {
        case .mirrors: return "Delete from mirrors"
        case .everywhere: return "Delete everywhere"
        }
    }
}

private struct MediaDeleteConfirmation: ViewModifier {
    @Binding var scope: MediaDeleteScope?
    /// The blob's hash. When some of your posts link it, Delete everywhere
    /// also offers to delete them, so no post is left showing a dead image.
    let hash: String?
    let action: (MediaDeleteScope) -> Void

    private var postCount: Int {
        guard scope == .everywhere, let hash else { return 0 }
        return NostrService.shared.ownEvents(referencingBlob: hash).count
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { scope != nil },
            set: { if !$0 { scope = nil } }
        )
    }

    func body(content: Content) -> some View {
        let posts = postCount
        content.alert(scope?.title ?? "", isPresented: isPresented, presenting: scope) { pending in
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            if pending == .everywhere, posts > 0, let hash {
                Button(posts == 1 ? "Delete file and post" : "Delete file and \(posts) posts", role: .destructive) {
                    Task {
                        // Posts first: if they can't be deleted (signing
                        // failed), keep the file too rather than leave them
                        // showing a broken image.
                        guard await NostrService.shared.deleteOwnEvents(referencingBlob: hash) > 0 else {
                            ErrorNotificationManager.shared.show("Couldn't delete the post, so the file was kept. Try again.")
                            return
                        }
                        action(pending)
                    }
                }
                Button("Delete file only", role: .destructive) { action(pending) }
            } else {
                Button(pending.confirmTitle, role: .destructive) { action(pending) }
            }
        } message: { pending in
            if pending == .everywhere, posts > 0 {
                Text(pending.message + (posts == 1
                    ? " One of your posts uses it and will show a broken image unless you delete that post too. Deleting the post removes all of it: its text and any other photos in it."
                    : " \(posts) of your posts use it and will show a broken image unless you delete them too. Deleting a post removes all of it: its text and any other photos in it."))
            } else {
                Text(pending.message)
            }
        }
    }
}

extension View {
    /// Ask before deleting a media blob. Setting `scope` presents the alert;
    /// confirming runs `action` with it, and either button clears it. With
    /// `hash`, Delete everywhere offers to delete your posts that use it.
    func confirmMediaDelete(
        _ scope: Binding<MediaDeleteScope?>,
        hash: String?,
        action: @escaping (MediaDeleteScope) -> Void
    ) -> some View {
        modifier(MediaDeleteConfirmation(scope: scope, hash: hash, action: action))
    }
}

extension View {
    /// Ask before blocking someone from a menu. One wording for every menu on
    /// both apps (Android's feed and Relay tab ask the same): "Block User",
    /// "Block this user? Their posts will be hidden from your feed.", Cancel /
    /// Block. The avatar quick menu blocks at once and shows a toast instead.
    func confirmBlockUser(isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        confirmDestructive(
            "Block User",
            isPresented: isPresented,
            consequence: "Block this user? Their posts will be hidden from your feed.",
            confirmTitle: "Block",
            action: action
        )
    }
}
