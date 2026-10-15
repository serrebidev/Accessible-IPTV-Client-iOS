import XCTest
@testable import IPTVCore

final class PrefsTests: XCTestCase {
	var defaults: UserDefaults!
	var prefs: Prefs!

	override func setUp() {
		let name = "test-\(UUID().uuidString)"
		defaults = UserDefaults(suiteName: name)!
		prefs = Prefs(defaults)
	}

	func named(_ n: String...) -> [Channel] { n.enumerated().map { Channel(sourceId: "s", itemId: "\($0.offset)", name: $0.element, group: "G", url: "u\($0.offset)") } }

	func testSearchPutsExactAndWordStartFirst() {
		let hits = Lists.searchRanked(named("PEACOCK 03 Breeders Cup Challenge Live", "The Challenge", "Challenge", "Unchallenged", "BBC"), "challenge")
		XCTAssertEqual(hits.map(\.name), ["Challenge", "The Challenge", "PEACOCK 03 Breeders Cup Challenge Live", "Unchallenged"])
	}

	func testSearchIsCaseInsensitiveAndTrimsTheQuery() {
		XCTAssertEqual(Lists.searchRanked(named("BBC One", "ITV"), "  bbc ").map(\.name), ["BBC One"])
		XCTAssertEqual(Lists.searchRanked(named("A", "B"), "").count, 2)
	}

	/// Some feeds carry names in decomposed form; the query comes from the keyboard, usually composed.
	func testSearchMatchesDecomposedAndComposedAccents() {
		XCTAssertEqual(Lists.searchRanked(named("Cafe\u{301} TV"), "caf\u{E9}").map(\.name), ["Cafe\u{301} TV"])
		XCTAssertEqual(Lists.searchRanked(named("Caf\u{E9} TV"), "cafe\u{301}").map(\.name), ["Caf\u{E9} TV"])
	}

	/// Both hit at a word start, so the shorter name comes first by characters, not by UTF-8 bytes,
	/// which would tie here and leave them in playlist order.
	func testSearchRanksShorterNamesFirstByCharacters() {
		XCTAssertEqual(Lists.searchRanked(named("Somethings", "Some Caf\u{E9}"), "some").map(\.name), ["Some Caf\u{E9}", "Somethings"])
	}

	func testXtreamAccountBehindAnM3uLink() {
		let src = Source(id: "1", type: Source.typeM3U, name: "Dispatcharr", url: "http://h:9191/get.php?username=me&password=pw")
		let x = Lists.xtreamBehind(src)!
		XCTAssertEqual(x.type, Source.typeXtream)
		XCTAssertEqual(x.url, "http://h:9191")
		XCTAssertEqual(x.username, "me")
		var plain = src
		plain.url = "http://h/list.m3u"
		XCTAssertNil(Lists.xtreamBehind(plain))
	}

	func testRecentListIsCappedAndDeduplicated() {
		for i in 0..<25 { prefs.addRecent("k\(i)") }
		prefs.addRecent("k20")
		XCTAssertEqual(prefs.recent.count, 20)
		XCTAssertEqual(prefs.recent[0], "k20")
		XCTAssertEqual(prefs.recent.filter { $0 == "k20" }.count, 1)
	}

	func testHistoricalBufferDefaultsBecomeTwentyFiveWithoutChangingCustomSettings() {
		XCTAssertEqual(prefs.bufferSeconds, 25)
		XCTAssertEqual(prefs.maxBufferSeconds, 30)
		for old in [6.0, 10.0] {
			prefs.bufferSeconds = old
			prefs.maxBufferSeconds = 18
			XCTAssertEqual(prefs.bufferSeconds, 25)
			XCTAssertEqual(prefs.maxBufferSeconds, 30)
		}
		prefs.bufferSeconds = 8
		prefs.maxBufferSeconds = 12
		XCTAssertEqual(prefs.bufferSeconds, 8)
		XCTAssertEqual(prefs.maxBufferSeconds, 12)
		prefs.bufferSeconds = 10
		XCTAssertEqual(prefs.maxBufferSeconds, 25, "a custom ceiling cannot undercut the migrated cushion")
	}

	func testExportImportRoundTripsEverything() throws {
		prefs.sources = [Source(id: "a", type: Source.typeXtream, name: "X", url: "http://h", username: "u", password: "p")]
		prefs.favorites = ["a:1", "a:2"]
		prefs.bufferSeconds = 9.5
		prefs.epgDaysAhead = 5
		prefs.lastEpgImport = 123
		prefs.preferAudioDescription = false
		prefs.rememberTrack("a:1", "English")
		let file = try prefs.export()
		prefs.sources = []; prefs.favorites = []; prefs.bufferSeconds = 1; prefs.epgDaysAhead = 1; prefs.preferAudioDescription = true
		try prefs.importSettings(file)
		XCTAssertEqual(prefs.sources.first?.username, "u")
		XCTAssertEqual(prefs.favorites, ["a:1", "a:2"])
		XCTAssertEqual(prefs.bufferSeconds, 9.5)
		XCTAssertEqual(prefs.epgDaysAhead, 5)
		XCTAssertEqual(prefs.lastEpgImport, 123)
		XCTAssertFalse(prefs.preferAudioDescription)
		XCTAssertEqual(prefs.rememberedTrack("a:1"), "English")
		XCTAssertThrowsError(try prefs.importSettings(Data(#"{"app":"other"}"#.utf8)))
		XCTAssertEqual(prefs.epgDaysAhead, 5, "a bad file changes nothing")
	}

	func testAndroidExportImports() throws {
		let android = #"""
		{"app":"AccessibleIPTV-Android","settings":{
		 "sources":{"s":"[{\"id\":\"a\",\"type\":\"m3u\",\"name\":\"L\",\"url\":\"http://h/l.m3u\",\"username\":\"\",\"password\":\"\",\"epgUrl\":\"\",\"mac\":\"\"}]"},
		 "favorites":{"set":["a:x|BBC"]},"bufferSeconds":{"f":12.5},"announceLevel":{"i":3},"lastEpgImport":{"l":99},"speakSubtitles":{"b":false}}}
		"""#
		try prefs.importSettings(Data(android.utf8))
		XCTAssertEqual(prefs.sources.first?.url, "http://h/l.m3u")
		XCTAssertEqual(prefs.favorites, ["a:x|BBC"])
		XCTAssertEqual(prefs.bufferSeconds, 12.5)
		XCTAssertEqual(prefs.announceLevel, 3)
		XCTAssertEqual(prefs.lastEpgImport, 99)
		XCTAssertFalse(prefs.speakSubtitles)
	}

	func testFavouritesToggle() {
		XCTAssertTrue(prefs.toggleFavorite("k"))
		XCTAssertEqual(prefs.favorites, ["k"])
		XCTAssertFalse(prefs.toggleFavorite("k"))
		XCTAssertEqual(prefs.favorites, [])
	}
}
