import XCTest
@testable import IPTVCore

final class GuideWindowTests: XCTestCase {
	private let hour: Int64 = 3_600_000

	private func show(_ title: String, _ start: Int64, _ stop: Int64) -> Programme {
		Programme(channelKey: "c", start: start, stop: stop, title: title)
	}

	func testLaterSkipsTheProgrammeOnNow() {
		let now = 10 * hour
		let list = [show("On now", 9 * hour, 11 * hour), show("Next", 11 * hour, 12 * hour), show("After", 12 * hour, 13 * hour)]
		XCTAssertEqual(GuideWindow.schedule(list, from: nil, to: nil, now: now, limit: 10).map(\.title), ["Next", "After"])
		XCTAssertEqual(GuideWindow.schedule(list, from: nil, to: nil, now: now, limit: 1).map(\.title), ["Next"])
	}

	func testANamedTimeIncludesTheProgrammeRunningThen() {
		let list = [show("Film", 19 * hour, 21 * hour), show("News", 21 * hour, 22 * hour)]
		XCTAssertEqual(GuideWindow.schedule(list, from: 20 * hour, to: 20 * hour + 1, now: hour, limit: 10).map(\.title), ["Film"])
		XCTAssertEqual(GuideWindow.schedule(list, from: 20 * hour, to: nil, now: hour, limit: 10).map(\.title), ["Film", "News"])
	}

	func testReversedRangeFallsBackToTheDefaultSpan() {
		let range = GuideWindow.range(from: 20 * hour, to: 8 * hour, now: hour)
		XCTAssertEqual(range.from, 20 * hour)
		XCTAssertEqual(range.to, 20 * hour + GuideWindow.defaultSpanMs)
	}

	func testSearchFilterNarrowsByTimeAndGroup() {
		let sport = Channel(sourceId: "s", itemId: "1", name: "Sky Sports", group: "UK Sport", url: "https://p/1")
		let news = Channel(sourceId: "s", itemId: "2", name: "News 24", group: "News", url: "https://p/2")
		let pairs = [(show("Morning", hour, 2 * hour), sport), (show("Evening", 20 * hour, 21 * hour), sport), (show("Evening news", 20 * hour, 21 * hour), news)]
		XCTAssertEqual(GuideWindow.filter(pairs, from: 18 * hour, to: nil, group: nil).map { $0.0.title }, ["Evening", "Evening news"])
		XCTAssertEqual(GuideWindow.filter(pairs, from: nil, to: 3 * hour, group: nil).map { $0.0.title }, ["Morning"])
		XCTAssertEqual(GuideWindow.filter(pairs, from: 18 * hour, to: nil, group: "sport").map { $0.0.title }, ["Evening"])
		XCTAssertEqual(GuideWindow.filter(pairs, from: nil, to: nil, group: "  ").count, 3)
	}

	func testFavoritesComeFirstKeepingOrder() {
		let a = Channel(sourceId: "s", itemId: "1", name: "A", group: "", url: "https://p/1")
		let b = Channel(sourceId: "s", itemId: "2", name: "B", group: "", url: "https://p/2")
		let c = Channel(sourceId: "s", itemId: "3", name: "C", group: "", url: "https://p/3")
		let pairs = [(show("1", 0, 1), a), (show("2", 0, 1), b), (show("3", 0, 1), c)]
		XCTAssertEqual(GuideWindow.favoritesFirst(pairs, favorites: [c.key]).map(\.1.name), ["C", "A", "B"])
	}

	func testRecordingWindowRefusesThePastAndBackwards() {
		let now = 10 * hour
		XCTAssertEqual(GuideWindow.recording(start: 12 * hour, end: nil, now: now)?.end, 13 * hour)
		XCTAssertEqual(GuideWindow.recording(start: 12 * hour, end: 14 * hour, now: now)?.end, 14 * hour)
		XCTAssertNil(GuideWindow.recording(start: 12 * hour, end: 11 * hour, now: now))
		XCTAssertNil(GuideWindow.recording(start: 8 * hour, end: 9 * hour, now: now))
		// Started already but not over yet: record the rest of it.
		XCTAssertEqual(GuideWindow.recording(start: 9 * hour, end: 11 * hour, now: now)?.start, 9 * hour)
	}

	func testOverlappingScheduleOnTheSameChannelCountsAsAlreadyScheduled() {
		let list = [Recording.Scheduled(id: 1, channelKey: "c", name: "C", title: "T", start: 10 * hour, end: 11 * hour)]
		XCTAssertTrue(GuideWindow.alreadyScheduled(list, channelKey: "c", start: 10 * hour, end: 11 * hour))
		XCTAssertTrue(GuideWindow.alreadyScheduled(list, channelKey: "c", start: 10 * hour + 1, end: 12 * hour))
		XCTAssertFalse(GuideWindow.alreadyScheduled(list, channelKey: "c", start: 11 * hour, end: 12 * hour))
		XCTAssertFalse(GuideWindow.alreadyScheduled(list, channelKey: "other", start: 10 * hour, end: 11 * hour))
	}

	func testSkipStaysInsideTheFile() {
		XCTAssertEqual(GuideWindow.skipped(from: 100, by: 30), 130)
		XCTAssertEqual(GuideWindow.skipped(from: 10, by: -30), 0)
		XCTAssertNil(GuideWindow.skipped(from: 0, by: -30))
		XCTAssertNil(GuideWindow.skipped(from: 100, by: 0))
		XCTAssertNil(GuideWindow.skipped(from: .nan, by: 5))
	}

	func testAccountSummaryKeepsOnlyStatusAndExpiry() {
		let rows = [("Status", "Active"), ("Expires", "Never"), ("Trial", "No"), ("Connections in use", "1 of 2")]
		XCTAssertEqual(GuideWindow.accountSummary(rows), ["Status: Active", "Expires: Never"])
		XCTAssertEqual(GuideWindow.accountSummary([]), [])
	}
}
