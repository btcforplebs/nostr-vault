import XCTest
@testable import MediaLogic

final class EmojiPaletteTests: XCTestCase {
    private let pepe = ReactionPick(CustomEmoji(shortcode: "pepe", url: "https://x.example/p.png"))
    private func u(_ e: String) -> ReactionPick { ReactionPick(e) }

    func testRecentsAreNewestFirstOnceEachCapped() {
        var state = EmojiPalette.State()
        for e in ["🔥", "😂", "🔥"] { state = EmojiPalette.recordUse(state, u(e)) }
        state = EmojiPalette.recordUse(state, pepe)
        XCTAssertEqual(state.recents.map(\.content), [":pepe:", "🔥", "😂"])
        for i in 0..<40 { state = EmojiPalette.recordUse(state, u("x\(i)")) }
        XCTAssertEqual(state.recents.count, EmojiPalette.recentsMax)
        XCTAssertEqual(state.recents.first?.content, "x39")
    }

    func testTheSameShortcodeWithAnotherImageIsAnotherEmoji() {
        let other = ReactionPick(CustomEmoji(shortcode: "pepe", url: "https://y.example/p.png"))
        let state = EmojiPalette.recordUse(EmojiPalette.recordUse(EmojiPalette.State(), pepe), other)
        XCTAssertEqual(state.recents.count, 2)
    }

    func testTheBarOrdersItselfByUseTiesKeepTheirPlace() {
        var state = EmojiPalette.State()
        XCTAssertEqual(EmojiPalette.orderedBar(state), EmojiPalette.defaultBar)
        state = EmojiPalette.recordUse(state, u("😢"))
        state = EmojiPalette.recordUse(state, u("😢"))
        state = EmojiPalette.recordUse(state, u("🔥"))
        XCTAssertEqual(EmojiPalette.orderedBar(state).map(\.content), ["😢", "🔥", "❤️", "🤙", "😂", "😮"])
    }

    func testUsingAnEmojiOffTheBarDoesNotChangeWhatIsOnIt() {
        let state = EmojiPalette.recordUse(EmojiPalette.State(), u("🍕"))
        XCTAssertEqual(Set(EmojiPalette.orderedBar(state)), Set(EmojiPalette.defaultBar))
    }

    func testEditingASlotPutsTheEmojiThereOrSwaps() {
        var state = EmojiPalette.replaceSlot(EmojiPalette.State(), replacing: u("🤙"), with: pepe)
        XCTAssertEqual(state.slots.map(\.content), ["❤️", ":pepe:", "🔥", "😂", "😮", "😢"])
        state = EmojiPalette.replaceSlot(state, replacing: u("❤️"), with: u("😢"))
        XCTAssertEqual(state.slots.map(\.content), ["😢", ":pepe:", "🔥", "😂", "😮", "❤️"])
        XCTAssertEqual(EmojiPalette.replaceSlot(state, replacing: u("🍕"), with: u("🎉")), state)
    }

    func testABrokenSavedBarIsMadeWhole() {
        let broken = EmojiPalette.State(slots: [pepe, pepe, u("🔥")])
        XCTAssertEqual(EmojiPalette.normalized(broken).slots.map(\.content), [":pepe:", "🔥", "❤️", "🤙", "😂", "😮"])
    }

    func testUseCountsStayBoundedAndKeepTheBars() {
        var state = EmojiPalette.State()
        for i in 0..<(EmojiPalette.countsMax + 50) { state = EmojiPalette.recordUse(state, u("e\(i)")) }
        state = EmojiPalette.recordUse(state, u("❤️"))
        XCTAssertLessThanOrEqual(state.counts.count, EmojiPalette.countsMax)
        XCTAssertEqual(state.counts["❤️"], 1)
    }

    func testTheHoldBarKeepsTheDefaultReaction() {
        let bar = [pepe] + ["🔥", "😂", "😮", "😢", "🤙"].map(u)
        XCTAssertEqual(EmojiPalette.tapbackOptions(defaultDisplay: "❤️", bar: bar).map(\.content),
                       ["❤️", ":pepe:", "🔥", "😂", "😮", "😢"])
        XCTAssertEqual(EmojiPalette.tapbackOptions(defaultDisplay: "🔥", bar: bar), bar)
    }

    func testStateRoundTripsThroughJSON() throws {
        let state = EmojiPalette.recordUse(EmojiPalette.replaceSlot(EmojiPalette.State(), replacing: u("🤙"), with: pepe), pepe)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EmojiPalette.State.self, from: data), state)
    }
}
