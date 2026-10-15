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
}
