import AppIntents
import IPTVCore
import XCTest
@testable import AccessibleIPTV

final class ChannelIntentTests: XCTestCase {
	func testProviderNameAndNumberBecomeSpokenSynonyms() {
		let channel = Channel(sourceId: "s", itemId: "42", name: "UK: Sky | Mix HD", group: "Entertainment",
			url: "https://provider/live/user/password/42.ts", attrs: [Channel.chno: "42"])
		let entity = TVChannelEntity(channel)
		XCTAssertEqual(entity.name, channel.name)
		XCTAssertEqual(entity.displayRepresentation.synonyms.map { String(localized: $0) }, ["Sky Mix", "42"])
		XCTAssertEqual(entity.id, TVChannelEntity(channel).id)
		XCTAssertFalse(entity.id.contains("password"))
	}

	func testCredentialBearingLabelsNeverBecomeSynonyms() {
		let channel = Channel(sourceId: "s", itemId: "42", name: "https://user:password@provider/live", group: "",
			url: "https://provider/live", attrs: [Channel.chno: "https://user:password@provider/42"])
		let entity = TVChannelEntity(channel)
		XCTAssertTrue(entity.displayRepresentation.synonyms.isEmpty)
		XCTAssertFalse(entity.name.contains("password"))
	}
}
