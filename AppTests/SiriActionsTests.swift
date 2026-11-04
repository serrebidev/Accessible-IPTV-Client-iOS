import AppIntents
import IPTVCore
import XCTest
@testable import AccessibleIPTV

final class SiriActionsTests: XCTestCase {
	private func channel(_ itemId: String, _ name: String, group: String = "Sport") -> Channel {
		Channel(sourceId: "s", itemId: itemId, name: name, group: group, url: "https://user:secret@provider/\(itemId)")
	}

	func testAppShortcutsStayWithinApplesLimit() {
		XCTAssertLessThanOrEqual(IPTVShortcuts.appShortcuts.count, 10)
	}

	func testSharedProgrammeTextNeverCarriesTheStreamAddress() {
		let ch = channel("1", "Sky Mix")
		let entity = ProgrammeEntity(Programme(channelKey: ch.key, start: 1_798_761_600_000, stop: 1_798_765_200_000, title: "Match of the Day"), ch)
		XCTAssertTrue(entity.shareText.hasPrefix("Match of the Day. Sky Mix."), entity.shareText)
		XCTAssertFalse(entity.shareText.contains("secret"))
		XCTAssertFalse(entity.shareText.contains("provider"))
	}

	func testScheduleAnswerNamesTheChannelOnceAndAddsTheDateOnlyOnAnotherDay() {
		let now: Int64 = 1_798_761_600_000
		XCTAssertEqual(GuideSpeech.when(now + 60_000, now: now), Format.time(now + 60_000))
		XCTAssertEqual(GuideSpeech.when(now + 3 * 86_400_000, now: now), Format.dateTime(now + 3 * 86_400_000))
		let shows = (0..<6).map { Programme(channelKey: "c", start: now + Int64($0) * 3_600_000, stop: now + Int64($0 + 1) * 3_600_000, title: "Show \($0)") }
		let spoken = GuideSpeech.schedule("Sky Mix", shows)
		XCTAssertTrue(spoken.hasPrefix("Sky Mix. Show 0,"), spoken)
		XCTAssertEqual(spoken.components(separatedBy: "Sky Mix").count, 2)
		XCTAssertFalse(spoken.contains("Show 4"))
	}

	func testScheduledRecordingEntityResolvesByItsId() {
		let entity = ScheduledRecordingEntity(Recording.Scheduled(id: 7, channelKey: "c", name: "UK: Sky Mix", title: "", start: 1_000, end: 2_000))
		XCTAssertEqual(entity.id, "7")
		XCTAssertEqual(entity.scheduleId, 7)
		// An untitled recording goes by its channel, so Siri has a name to read.
		XCTAssertEqual(entity.title, "UK: Sky Mix")
	}

	func testCredentialBearingNameNeverReachesARecordingEntity() {
		let entity = ScheduledRecordingEntity(Recording.Scheduled(id: 1, channelKey: "c", name: "http://user:secret@provider/1", title: "", start: 1_000, end: 2_000))
		XCTAssertFalse(entity.channelName.contains("secret"))
		XCTAssertFalse(entity.title.contains("secret"))
	}

	func testPublicSnippetRowsListAtMostFive() {
		let ch = channel("1", "Sky Mix")
		let pairs = (0..<9).map { (Programme(channelKey: ch.key, start: Int64($0) * 3_600_000, stop: Int64($0 + 1) * 3_600_000, title: "Show \($0)"), ch) }
		XCTAssertEqual(GuideSnippet(heading: "Sky Mix", pairs: pairs).rows.count, 5)
	}
}
