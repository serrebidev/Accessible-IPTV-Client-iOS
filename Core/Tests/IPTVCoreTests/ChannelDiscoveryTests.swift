import XCTest
@testable import IPTVCore

final class ChannelDiscoveryTests: XCTestCase {
	private func channel(_ id: String, _ name: String, number: String = "") -> Channel {
		Channel(sourceId: "s", itemId: id, name: name, group: "News", url: "http://h/\(id)", attrs: [Channel.chno: number])
	}

	func testNamesAreRankedAndBlankQueriesReturnNothing() {
		let channels = [channel("1", "BBC One HD"), channel("2", "BBC One"), channel("3", "Other")]
		XCTAssertEqual(ChannelDiscovery.matching(channels, "bbc one").map(\.itemId), ["2", "1"])
		XCTAssertTrue(ChannelDiscovery.matching(channels, " \n").isEmpty)
		XCTAssertTrue(ChannelDiscovery.matching(channels, "missing").isEmpty)
	}

	func testNumbersKeepAmbiguousProviderMatchesForSiriToDisambiguate() {
		let channels = [channel("1", "A", number: "42"), channel("2", "B", number: "42")]
		XCTAssertEqual(ChannelDiscovery.matching(channels, "42").count, 2)
		XCTAssertEqual(ChannelDiscovery.matching(channels, "2").first?.itemId, "2")
		XCTAssertTrue(ChannelDiscovery.matching(channels, "0").isEmpty)
	}

	func testSuggestionsAreBoundedDeduplicatedAndKeepRecentOrder() {
		let channels = (1...30).map { channel(String($0), "Channel \($0)") }
		let result = ChannelDiscovery.suggestions(channels, favorites: ["s:4"], recent: ["s:3", "s:4", "s:2", "missing"])
		XCTAssertEqual(Array(result.prefix(4)).map(\.itemId), ["4", "3", "2", "1"])
		XCTAssertEqual(result.count, 20)
		XCTAssertEqual(Set(result.map(\.key)).count, 20)
	}

	func testUnnamedPlaylistURLsAreNotPublishedAsSiriLabels() {
		let channel = M3U.parse(sourceId: "s", text: "#EXTM3U\n#EXTINF:-1,\nhttp://host/live/USER/PASS/42.ts")[0]
		XCTAssertTrue(channel.key.contains("PASS"))
		XCTAssertEqual(ChannelDiscovery.publicText(channel.name), "")
		XCTAssertEqual(ChannelDiscovery.publicText("BBC One"), "BBC One")
		XCTAssertEqual(ChannelDiscovery.publicText("http://USER:PASS@host/category"), "")
	}

	func testSpokenNamesMatchProviderDecorationWithoutConfusingTimeshiftChannels() {
		let channels = [channel("1", "Sky Mix +1"), channel("2", "UK: Sky | Mix HD"), channel("3", "Sky Mix")]
		XCTAssertEqual(ChannelDiscovery.matching(channels, "Sky Mix").map(\.itemId), ["3", "2", "1"])
		XCTAssertEqual(ChannelDiscovery.matching(channels, "Sky Mix +1").map(\.itemId), ["1"])
		XCTAssertEqual(ChannelDiscovery.matching(Array(channels.prefix(2)), "Sky Mix").first?.itemId, "2")
	}

	func testSpokenAliasesKeepWordsNumbersAndTimeshiftAndHideURLs() {
		XCTAssertEqual(ChannelDiscovery.spokenName("UK: Sky | Mix HD"), "Sky Mix")
		XCTAssertEqual(ChannelDiscovery.spokenName("Sky Mix +1 FHD"), "Sky Mix +1")
		XCTAssertEqual(ChannelDiscovery.spokenName("Film4"), "Film4")
		XCTAssertEqual(ChannelDiscovery.spokenName("http://USER:PASS@host/live"), "")
		XCTAssertEqual(ChannelDiscovery.spokenName("HD"), "")
	}

	func testEveryFavoriteAndRecentChannelRemainsInSiriVocabulary() {
		let channels = (1...60).map { channel(String($0), "Channel \($0)") }
		let favorites = Set(channels.prefix(30).map(\.key))
		let result = ChannelDiscovery.suggestions(channels, favorites: favorites, recent: ["s:60", "s:1", "missing"])
		XCTAssertEqual(result.map(\.itemId), (1...30).map(String.init) + ["60"])
	}

	func testSpokenPartialNamesSearchAcrossProviderPunctuation() {
		let channels = [channel("1", "Sky Mix +1"), channel("2", "UK: Sky | Mix HD"), channel("3", "Sky Sports")]
		XCTAssertEqual(ChannelDiscovery.matching(channels, "sky mi").map(\.itemId), ["2", "1"])
		XCTAssertEqual(ChannelDiscovery.matching(channels, "skymix").map(\.itemId), ["2", "1"])
		XCTAssertTrue(ChannelDiscovery.matching(channels, "!!!").isEmpty)
	}

	func testResolvedNamesAreNotCrowdedOutByLookAlikeSiblings() {
		let channels = (1...30).map { channel(String($0), "UK| SKY SPORTS \($0) HD", number: "10\($0)") }
			+ [channel("f1", "UK| SKY SPORTS F1 HD", number: "1040"), channel("news", "UK| SKY SPORTS NEWS HD", number: "1041")]
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "Sky Sports F1").map(\.itemId), ["f1"])
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "sky sports news").map(\.itemId), ["news"])
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "1040").map(\.itemId), ["f1"])
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "sky sports").count, 20)
	}

	func testResolvedNamesDropTimeshiftAndKeepTheNumberPath() {
		let channels = [channel("1", "Sky Mix +1"), channel("2", "UK: Sky | Mix HD"), channel("3", "Sky Mix")]
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "Sky Mix").map(\.itemId), ["2", "3"])
		XCTAssertEqual(ChannelDiscovery.resolve(channels, "sky mix +1").map(\.itemId), ["1"])
		let numbered = [channel("1", "BBC One HD", number: "101"), channel("2", "BBC Two HD", number: "102")]
		XCTAssertEqual(ChannelDiscovery.resolve(numbered, "101").map(\.itemId), ["1"])
		XCTAssertEqual(ChannelDiscovery.resolve(numbered, "bbc two").map(\.itemId), ["2"])
		XCTAssertTrue(ChannelDiscovery.resolve(numbered, "  \n ").isEmpty)
		XCTAssertTrue(ChannelDiscovery.resolve(numbered, "missing").isEmpty)
	}
}
