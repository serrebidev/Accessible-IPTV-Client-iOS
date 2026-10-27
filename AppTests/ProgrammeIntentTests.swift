import AppIntents
import IPTVCore
import XCTest
@testable import AccessibleIPTV

final class ProgrammeIntentTests: XCTestCase {
	private func channel(_ itemId: String, _ name: String, group: String = "Sport") -> Channel {
		Channel(sourceId: "s", itemId: itemId, name: name, group: group, url: "https://provider/\(itemId)")
	}

	private func programme(_ ch: Channel, start: Int64, title: String, description: String = "") -> Programme {
		Programme(channelKey: ch.key, start: start, stop: start + 3_600_000, title: title,
			description: description, channelName: ch.name)
	}

	func testIdentifierCarriesTheSlotAndParsesBack() {
		let ch = channel("1", "Sky Mix")
		let p = programme(ch, start: 1_798_761_600_000, title: "Match of the Day")
		let entity = ProgrammeEntity(p, ch)
		XCTAssertEqual(entity.id, "\(ch.key)|1798761600000")
		XCTAssertEqual(ProgrammeEntity.parse(entity.id)?.channelKey, ch.key)
		XCTAssertEqual(ProgrammeEntity.parse(entity.id)?.startMs, 1_798_761_600_000)
		XCTAssertNil(ProgrammeEntity.parse("no-slot-here"))
		XCTAssertEqual(entity.title, "Match of the Day")
		XCTAssertEqual(entity.channelName, "Sky Mix")
		XCTAssertEqual(entity.category, "Sport")
		XCTAssertFalse(entity.id.contains("provider"))
	}

	func testQueryResolvesOnlyTheNamedSlots() {
		let a = channel("1", "Sky Mix"), b = channel("2", "BBC One", group: "General")
		let p1 = programme(a, start: 1_000, title: "One")
		let p2 = programme(b, start: 2_000, title: "Two")
		let pairs = [(p1, a), (p2, b)]
		let found = ProgrammeQuery.resolve([ProgrammeEntity.identifier(p2), "gone|9", ProgrammeEntity.identifier(p1)], in: pairs)
		XCTAssertEqual(found.map(\.title), ["Two", "One"])
		XCTAssertEqual(ProgrammeQuery.entities(from: pairs, limit: 1).map(\.title), ["One"])
	}

	func testSpokenDialogIsSentencesAndShorterThanTheFullText() {
		let ch = channel("1", "Sky Mix")
		let pairs = (0..<6).map { (programme(ch, start: 1_798_761_600_000 + Int64($0) * 3_600_000, title: "Show \($0)"), ch) }
		let spoken = GuideSpeech.spoken(pairs)
		XCTAssertTrue(spoken.hasPrefix("Sky Mix. Show 0."), spoken)
		XCTAssertTrue(spoken.hasSuffix("."), spoken)
		XCTAssertFalse(spoken.contains("Show 3"))
		let full = GuideSpeech.full(pairs)
		XCTAssertEqual(full.split(separator: "\n").count, 5)
		XCTAssertTrue(full.contains("Show 4"))
	}

	func testNaturalFilterAppliesKeywordsCategoryChannelAndHours() {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(identifier: "UTC")!
		func at(_ hour: Int) -> Int64 {
			var parts = DateComponents()
			parts.year = 2026; parts.month = 10; parts.day = 27; parts.hour = hour
			return Int64(calendar.date(from: parts)!.timeIntervalSince1970 * 1000)
		}
		let sport = channel("1", "Sky Sports", group: "Sport")
		let news = channel("2", "News 24", group: "News")
		let football = (programme(sport, start: at(20), title: "Live Football", description: "Premier League"), sport)
		let darts = (programme(sport, start: at(15), title: "Darts", description: "Championship"), sport)
		let bulletin = (programme(news, start: at(20), title: "Football Report", description: "Results"), news)
		let all = [football, darts, bulletin]

		var spec = GuideFilterSpec()
		spec.category = "sport"
		XCTAssertEqual(GuideNaturalFilter.apply(spec, to: all, calendar: calendar).map { $0.0.title }, ["Live Football", "Darts"])

		spec = GuideFilterSpec()
		spec.keywords = "football"
		spec.earliestHour = 18
		XCTAssertEqual(GuideNaturalFilter.apply(spec, to: all, calendar: calendar).map { $0.0.title }, ["Live Football", "Football Report"])

		spec = GuideFilterSpec()
		spec.channelText = "news"
		spec.latestHour = 19
		XCTAssertTrue(GuideNaturalFilter.apply(spec, to: all, calendar: calendar).isEmpty)

		XCTAssertEqual(GuideNaturalFilter.apply(GuideFilterSpec(), to: all, calendar: calendar).count, 3)
		XCTAssertTrue(GuideFilterSpec().isEmpty)
		XCTAssertEqual(GuideFilterSpec(keywords: "x").searchTerm, "x")
	}

	#if os(iOS)
	func testAudioSchemaEntityKeepsTheChannelIdentifiers() {
		guard #available(iOS 27.0, *) else { return }
		let ch = channel("42", "UK: Sky | Mix HD", group: "Entertainment")
		let schema = LiveChannelSchemaEntity(ch)
		XCTAssertEqual(schema.id, TVChannelEntity.identifier(ch))
		XCTAssertEqual(schema.title, "Sky Mix")
	}
	#endif
}
