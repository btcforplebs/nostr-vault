import SwiftUI

/// Calendar: an event from a shared .ics file or the page's JSON-LD, edited
/// here and published as a NIP-52 calendar event (public) on Publish.
struct CalendarReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var loading = true
    @State private var title = ""
    @State private var details = ""
    @State private var location = ""
    @State private var link = ""
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var tzid: String?
    @State private var publishing = false
    @State private var error: String?

    var body: some View {
        Form {
            if loading {
                Section { HStack { ProgressView(); Text("Reading the event…").foregroundStyle(.secondary) } }
            } else {
                Section("Event") {
                    TextField("Title", text: $title)
                    Toggle("All day", isOn: $allDay)
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    TextField("Location", text: $location)
                    TextField("Link", text: $link)
                }
                Section("Details") { TextEditor(text: $details).frame(minHeight: 90) }
                SharePortalAccountSection(intent: intent)
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                SharePortalActionButton(title: "Publish", busy: publishing,
                                        enabled: SharePortalAccountSection.isReady(intent)
                                            && !title.trimmingCharacters(in: .whitespaces).isEmpty,
                                        footer: "Calendar events are public.") { publish() }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard loading else { return }
        var ev = CalendarShareEvent()
        if let file = intent.files.first(where: { $0.mime.lowercased() == "text/calendar" || $0.name.lowercased().hasSuffix(".ics") }),
           let url = SharePortalInbox.shared.fileURL(for: file, of: intent),
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            ev = CalendarShareParser.parseICS(text, defaultZone: .current)
        } else if let html = await SharePageFetcher.html(intent.source.url) {
            ev = CalendarShareParser.parseEvent(html: html)
        }
        title = ev.title.isEmpty ? (intent.source.title ?? "") : ev.title
        details = ev.description
        location = ev.location
        link = ev.url.isEmpty ? (intent.source.url ?? "") : ev.url
        tzid = ev.tzid
        allDay = ev.isAllDay
        if let s = ev.start.flatMap(Self.date) { start = s }
        if let e = ev.end.flatMap(Self.date) {
            // NIP-52 and ICS all-day ends are exclusive; the picker shows the last day.
            end = allDay ? e.addingTimeInterval(-86_400) : e
        } else {
            end = allDay ? start : start.addingTimeInterval(3600)
        }
        if end < start { end = start }
        loading = false
    }

    /// An all-day date as midnight in the device's zone, so the picker shows that day.
    static func date(_ w: CalendarShareEvent.When) -> Date? {
        switch w {
        case .time(let t): return Date(timeIntervalSince1970: TimeInterval(t))
        case .date(let s):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)
        }
    }

    static func ymd(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func publish() {
        var ev = CalendarShareEvent(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    description: details.trimmingCharacters(in: .whitespacesAndNewlines),
                                    location: location.trimmingCharacters(in: .whitespacesAndNewlines),
                                    url: link.trimmingCharacters(in: .whitespacesAndNewlines))
        if allDay {
            ev.start = .date(Self.ymd(start))
            ev.end = .date(Self.ymd(end.addingTimeInterval(86_400)))
        } else {
            ev.start = .time(Int(start.timeIntervalSince1970))
            ev.end = .time(Int(end.timeIntervalSince1970))
            ev.tzid = tzid ?? TimeZone.current.identifier
        }
        let tags = CalendarShareTags.tags(ev, d: UUID().uuidString.lowercased())
        publishing = true
        error = nil
        Task {
            do {
                try await SharePortalPosting.publish(kind: CalendarShareTags.kind(for: ev), content: ev.description,
                                                     tags: tags, for: intent)
                close()
            } catch {
                self.error = error.localizedDescription
                publishing = false
            }
        }
    }
}
