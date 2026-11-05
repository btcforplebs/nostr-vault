import Foundation

/// Which reply or quote target a composer posts with.
///
/// A composer opened as a Reply (or Quote) has its own target. Picking a
/// saved draft there must post the draft as it was saved: a standalone
/// draft (nil target) used to fall back to the composer's own note, so it
/// went out as a reply to that note and tagged its author.
enum ComposerContext {
    /// Once a draft is loaded its value wins, nil included; before that the
    /// composer's own target is used.
    static func effective<T>(draftLoaded: Bool, draft: T?, composer: T?) -> T? {
        draftLoaded ? draft : composer
    }
}
