import SwiftUI

/// Calendar (§6.3): an .ics file or the page's JSON-LD Event, reviewed and published as NIP-52 (31922/31923).
struct CalendarShareHandler: SharePortalHandler {
    let action = NVShareAction.calendar

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(CalendarReviewView(intent: intent, close: close))
    }
}
