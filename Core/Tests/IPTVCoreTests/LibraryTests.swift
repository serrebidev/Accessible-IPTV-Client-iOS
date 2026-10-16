#if canImport(SQLite3)
import XCTest
@testable import IPTVCore

/// Playlist loading, the channel cache, favourites, guides named by playlists, staleness.
/// Port of the Android AppTest, with a picked M3U file standing in for the fake server.
final class LibraryTests: XCTestCase {
	var dir: URL!
	var prefs: Prefs!
	var lib: Library!
	var playlist = ""
	var reads = 0
	var fail: Error?

	let src = Source(id: "src", type: Source.typeM3U, name: "List", url: Source.fileScheme + "x")

	static let text = """
		#EXTM3U x-tvg-url="http://g/guide.xml"
		#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://l/1.png" group-title="News" catchup="xc" catchup-days="2",BBC One
		http://h/live/u/p/1.ts
		#EXTINF:-1 group-title="Sport",Arena
		#EXTVLCOPT:http-user-agent=Box
		http://h/live/u/p/2.ts
		#EXTINF:-1 group-title="Films" tvg-type="movie",Film
		http://h/movie/u/p/3.mp4
		"""

	override func setUpWithError() throws {
		dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
		prefs = Prefs(UserDefaults(suiteName: "lib-\(UUID().uuidString)")!)
		prefs.sources = [src]
		playlist = LibraryTests.text
		try fresh()
	}

	/// A new Library over the same files: what a relaunch sees.
	func fresh() throws {
		lib = try Library(dir: dir, prefs: prefs)
		lib.readFile = { [unowned self] _ in
			reads += 1
			if let e = fail { throw e }
			return playlist
		}
	}

	override func tearDown() { lib = nil; try? FileManager.default.removeItem(at: dir) }

	func testLoadsSectionsAndKinds() async {
		let errors = await lib.load(Library.live, force: false)
		XCTAssertEqual(errors, [])
		XCTAssertEqual(lib.channels.map(\.name), ["BBC One", "Arena"])
		_ = await lib.load(Library.movies, force: false)
		XCTAssertEqual(lib.list(Library.movies).map(\.name), ["Film"])
		// "All" and "Favorites" first, then playlist order, with favourites counted in the same pass.
		prefs.toggleFavorite(lib.channels[1].key)
		let groups = lib.groupSummary(Library.live)
		XCTAssertEqual(groups.map(\.name), [Library.all, Library.favorites, "News", "Sport"])
		XCTAssertEqual(groups.map(\.count), [2, 1, 1, 1])
	}

	func testDiscoveryReceivesOnlyCompletedLiveLoadsIncludingEmptyCatalogues() async {
		var snapshots: [[Channel]] = []
		lib.liveChannelsDidLoad = { channels, _ in snapshots.append(channels) }
		_ = await lib.load(Library.live, force: false)
		XCTAssertEqual(snapshots.first?.map(\.name), ["BBC One", "Arena"])
		_ = await lib.load(Library.movies, force: false)
		XCTAssertEqual(snapshots.count, 1)
		prefs.sources = []
		_ = await lib.load(Library.live, force: false)
		XCTAssertEqual(snapshots.count, 2)
		XCTAssertTrue(snapshots.last?.isEmpty == true)
	}

	func testEditedSourceCannotPublishOrCacheAnOlderInFlightPlaylist() async throws {
		let replacement = Source(id: src.id, type: src.type, name: "Replacement", url: Source.fileScheme + "new")
		let updated = "#EXTM3U\n#EXTINF:-1,New channel\nhttp://new/live/1.ts"
		lib.readFile = { [unowned self] value in
			reads += 1
			if value == src.url {
				prefs.sources = [replacement]
				lib.forgetCache(src)
				return LibraryTests.text
			}
			return updated
		}
		_ = await lib.load(Library.live, force: true)
		XCTAssertEqual(lib.channels.map(\.name), ["New channel"])
		XCTAssertEqual(lib.liveSnapshot.sources, [replacement])
		XCTAssertEqual(reads, 2)
		playlist = updated
		try fresh()
		_ = await lib.load(Library.live, force: false)
		XCTAssertEqual(lib.channels.map(\.name), ["New channel"])
		XCTAssertEqual(reads, 2, "The new source cache must survive a relaunch")
	}

	func testCacheIsUsedAndRoundTripsEveryField() async throws {
		_ = await lib.load(Library.live, force: false)
		let fetched = lib.channels
		try fresh()
		_ = await lib.load(Library.live, force: false)
		XCTAssertEqual(reads, 1, "a fresh cache is not read again")
		XCTAssertEqual(lib.channels, fetched)
		XCTAssertEqual(M3U.splitHeaders(lib.channels[1].url).1["User-Agent"], "Box")
	}

	func testADownFailureKeepsTheCachedChannels() async {
		_ = await lib.load(Library.live, force: false)
		fail = NetError.status(503)
		let errors = await lib.load(Library.live, force: true)
		XCTAssertEqual(errors.count, 1)
		XCTAssertTrue(errors[0].contains("503"), errors[0])
		XCTAssertEqual(lib.channels.count, 2)
	}

	func testFavouritesSurviveTheProviderReorderingTheList() async {
		_ = await lib.load(Library.live, force: false)
		prefs.toggleFavorite(lib.channels.first { $0.name == "Arena" }!.key)
		playlist = "#EXTM3U\n#EXTINF:-1,New\nhttp://h/9.ts\n#EXTINF:-1 group-title=\"Sport\",Arena\nhttp://h/live/u/p/2.ts"
		_ = await lib.load(Library.live, force: true)
		XCTAssertEqual(lib.channelsIn(Library.live, Library.favorites).map(\.name), ["Arena"])
	}

	func testFavouritesFromPositionIdsAreMovedToTheNewIds() async throws {
		// Android 0.2.5 and older keyed M3U channels by position: "src:1" was Arena.
		let old = [Channel(sourceId: "src", itemId: "0", name: "BBC One", group: "News", url: "http://h/live/u/p/1.ts"),
		           Channel(sourceId: "src", itemId: "1", name: "Arena", group: "Sport", url: "http://h/live/u/p/2.ts|User-Agent=Box")]
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("channels_src_live.json"))
		prefs.favorites = ["src:1", "other:5"]
		_ = await lib.load(Library.live, force: true)
		XCTAssertEqual(lib.channelsIn(Library.live, Library.favorites).map(\.name), ["Arena"])
		XCTAssertTrue(prefs.favorites.contains("other:5"), "other sources' favourites are left alone")
	}

	func testAPlaylistsOwnGuideIsUsedButATypedOneWins() async {
		_ = await lib.load(Library.live, force: false)
		XCTAssertEqual(prefs.sources[0].effectiveEpgUrl, "http://g/guide.xml")
		var mine = src
		mine.epgUrl = "http://mine/g.xml"
		prefs.sources = [mine]
		_ = await lib.load(Library.live, force: true)
		XCTAssertEqual(prefs.sources[0].epgUrl, "http://mine/g.xml")
	}

	func testGuideImportAndStaleness() async throws {
		lib.openGuide = { _ in DataSource(Data("<tv><channel id=\"bbc1.uk\"><display-name>BBC One</display-name></channel></tv>".utf8)) }
		_ = await lib.load(Library.live, force: false)
		XCTAssertTrue(lib.guideStale())
		_ = try await lib.importGuide()
		XCTAssertFalse(lib.guideStale())
		// A channel the guide was not built for means import again now, not tomorrow.
		playlist = LibraryTests.text.replacingOccurrences(of: "Arena", with: "Arena 2")
		_ = await lib.load(Library.live, force: true)
		XCTAssertTrue(lib.guideStale())
	}

	/// Xtream and Stalker entries keep their id when the provider renames them or fixes a tvg-id,
	/// so a guide match remembered for that id must not outlive the list it was computed from.
	func testALiveReloadDropsTheCachedGuideMatch() async throws {
		lib.openGuide = { _ in DataSource(Data("<tv><channel id=\"bbc1.uk\"><display-name>BBC One</display-name></channel></tv>".utf8)) }
		_ = await lib.load(Library.live, force: false)
		_ = try await lib.importGuide()
		let entry = Channel(sourceId: "src", itemId: "17", name: "BBC One", group: "News", url: "u")
		XCTAssertEqual(lib.epg.guideId(entry), "bbc1.uk")
		_ = await lib.load(Library.live, force: true)
		let renamed = Channel(sourceId: "src", itemId: "17", name: "Nowhere News", group: "News", url: "u")
		XCTAssertNil(lib.epg.guideId(renamed))
	}

	func testRestoredScreensFindTheirChannel() async throws {
		_ = await lib.load(Library.movies, force: false)
		let key = lib.list(Library.movies)[0].key
		try fresh()
		let found = await lib.findChannel(key, section: Library.movies)
		XCTAssertEqual(found?.name, "Film")
	}

	func testCatchupOnlyInsideTheWindow() async {
		_ = await lib.load(Library.live, force: false)
		let bbc = lib.channels[0]
		let recent = nowMs() - 3_600_000
		let inside = await lib.catchupUrl(bbc, start: recent, stop: recent + 1_800_000)
		XCTAssertNotNil(inside)
		let outside = await lib.catchupUrl(bbc, start: nowMs() - 3 * 86_400_000, stop: nowMs() - 3 * 86_400_000 + 1_800_000)
		XCTAssertNil(outside)
		let arena = await lib.catchupUrl(lib.channels[1], start: recent, stop: recent + 60_000)
		XCTAssertNil(arena)
	}

	func testStalkerChannelWithoutItsPlaylistSaysSo() async {
		let ch = Channel(sourceId: "gone", itemId: "1", name: "X", group: "G", url: Channel.stalkerScheme + "ffrt http://x")
		do { _ = try await lib.resolveUrl(ch); XCTFail("resolved") } catch { XCTAssertEqual(error.localizedDescription, "Playlist removed") }
	}
}
#endif
