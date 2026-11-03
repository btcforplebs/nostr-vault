import Foundation

// MARK: - Which actions the share sheet offers
//
// The classifier ranks every action; the sheet only shows the ones the app
// can finish. Phase 1 ships Highlight and today's Upload. A phase 2 lane adds
// its own action here when its handler, form and review are in, and touches
// nothing else in SharePortalKit. Android twin: ShareActionAvailability.kt.

enum NVShareActionAvailability {
    static let ready: Set<NVShareAction> = [.highlight, .upload]

    static func offered(_ ranked: [NVShareAction]) -> [NVShareAction] {
        ranked.filter { ready.contains($0) }
    }
}
