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

	func testSavedChannelsResolveInRequestedOrderAndIgnoreUnavailableIDs() {
		let a = Channel(sourceId: "s", itemId: "1", name: "Sky Mix", group: "", url: "https://provider/1")
		let b = Channel(sourceId: "s", itemId: "2", name: "BBC One", group: "", url: "https://provider/2")
		let ids = [TVChannelEntity.identifier(b), "removed", TVChannelEntity.identifier(a)]
		XCTAssertEqual(TVChannelQuery.resolve(ids, in: [a, a, b]).map(\.name), ["BBC One", "Sky Mix"])
	}

	func testShortcutsFiltersRespectAllAnyAndLimit() {
		let a = Channel(sourceId: "s", itemId: "1", name: "Sky Mix", group: "Entertainment", url: "u")
		let b = Channel(sourceId: "s", itemId: "2", name: "BBC One", group: "General", url: "u")
		let filters: [(Channel) -> Bool] = [{ $0.name == "Sky Mix" }, { $0.group == "General" }]
		XCTAssertTrue(TVChannelQuery.find([a, b], matching: filters, mode: .and, sortedBy: [], limit: nil).isEmpty)
		XCTAssertEqual(TVChannelQuery.find([a, b], matching: filters, mode: .or, sortedBy: [], limit: 1).map(\.name), ["Sky Mix"])
		XCTAssertEqual(TVChannelQuery.find([a, b], matching: [], mode: .and, sortedBy: [], limit: nil).count, 2)
		XCTAssertTrue(TVChannelQuery.find([a, b], matching: [], mode: .and, sortedBy: [], limit: 0).isEmpty)
	}
}
