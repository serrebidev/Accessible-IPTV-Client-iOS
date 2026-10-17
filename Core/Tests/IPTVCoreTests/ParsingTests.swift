import XCTest
@testable import IPTVCore

/// Pure rules: playlist parsing, catch-up URLs, guide times, provider links, retry budgets.
/// Ported from the Android app's ParsingTest and CoreTest.
final class ParsingTests: XCTestCase {
	let utc = TimeZone(identifier: "UTC")!

	// ---- M3U ----

	func testByteOrderMarkDoesNotHideTheHeader() {
		let ch = M3U.parse(sourceId: "s", text: "\u{FEFF}#EXTM3U catchup=\"xc\" catchup-days=\"2\"\n#EXTINF:-1,A\nhttp://h/live/u/p/1.ts")
		XCTAssertEqual(ch.count, 1)
		XCTAssertEqual(ch[0].catchupDays, 2)
	}

	func testWindowsLineEndings() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTM3U\r\n#EXTINF:-1 group-title=\"News\",A\r\nhttp://h/1.ts\r\n")
		XCTAssertEqual(ch[0].name, "A")
		XCTAssertEqual(ch[0].group, "News")
		XCTAssertEqual(ch[0].url, "http://h/1.ts")
	}

	func testChannelIdsSurviveTheProviderAddingChannels() {
		let before = M3U.parse(sourceId: "s", text: "#EXTM3U\n#EXTINF:-1 tvg-id=\"bbc1\",BBC One\nhttp://h/1.ts\n#EXTINF:-1,ITV\nhttp://h/2.ts")
		let after = M3U.parse(sourceId: "s", text: "#EXTM3U\n#EXTINF:-1,New One\nhttp://h/9.ts\n#EXTINF:-1,ITV\nhttp://h/2.ts\n#EXTINF:-1 tvg-id=\"bbc1\",BBC One\nhttp://h/1.ts")
		XCTAssertEqual(before.first { $0.name == "BBC One" }!.key, after.first { $0.name == "BBC One" }!.key)
		XCTAssertEqual(before.first { $0.name == "ITV" }!.key, after.first { $0.name == "ITV" }!.key)
		// Same keys as the Android app, so favourites carry over with exported settings.
		XCTAssertEqual(before[0].key, "s:bbc1|BBC One")
	}

	func testRepeatedNamesStillGetDistinctKeys() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,Same\nhttp://h/1.ts\n#EXTINF:-1,Same\nhttp://h/2.ts")
		XCTAssertEqual(Set(ch.map(\.key)).count, 2)
		XCTAssertEqual(ch[1].itemId, "|Same#2")
	}

	func testVlcOptionsBecomeRequestHeaders() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=Mozilla/5.0 (X11)\n#EXTVLCOPT:http-referrer=http://site/\nhttp://h/1.ts")
		let (url, h) = M3U.splitHeaders(ch[0].url)
		XCTAssertEqual(url, "http://h/1.ts")
		XCTAssertEqual(h["User-Agent"], "Mozilla/5.0 (X11)")
		XCTAssertEqual(h["Referer"], "http://site/")
	}

	func testUserAgentAttributeIsApplied() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1 http-user-agent=\"Kodi/20\",A\nhttp://h/1.ts")
		XCTAssertEqual(M3U.splitHeaders(ch[0].url).1["User-Agent"], "Kodi/20")
	}

	func testPipeTailInTheUrlWinsOverPlaylistOptions() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=FromOpt\nhttp://h/1.ts|User-Agent=FromUrl")
		XCTAssertEqual(M3U.splitHeaders(ch[0].url).1["User-Agent"], "FromUrl")
	}

	func testOptionsDoNotLeakToTheNextChannel() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,A\n#EXTVLCOPT:http-user-agent=X\nhttp://h/1.ts\n#EXTINF:-1,B\nhttp://h/2.ts")
		XCTAssertEqual(ch[1].url, "http://h/2.ts")
	}

	func testUnquotedAndSingleQuotedAttributes() {
		let a = M3U.attributes("#EXTINF:-1 tvg-id=bbc1.uk group-title='UK News' tvg-logo=\"x\"")
		XCTAssertEqual(a["tvg-id"], "bbc1.uk")
		XCTAssertEqual(a["group-title"], "UK News")
		XCTAssertEqual(a["tvg-logo"], "x")
	}

	func testTitleFallsBackToTvgNameThenUrl() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1 tvg-name=\"Named\",\nhttp://h/1.ts\n#EXTINF:-1\nhttp://h/2.ts")
		XCTAssertEqual(ch[0].name, "Named")
		XCTAssertEqual(ch[1].name, "http://h/2.ts")
	}

	func testExtgrpAppliesToOneChannelOnly() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,A\n#EXTGRP:Sport\nhttp://h/1.ts\n#EXTINF:-1,B\nhttp://h/2.ts")
		XCTAssertEqual(ch[0].group, "Sport")
		XCTAssertEqual(ch[1].group, "Ungrouped")
	}

	func testLowercaseTagsAreAccepted() {
		let ch = M3U.parse(sourceId: "s", text: "#extm3u\n#extinf:-1 group-title=\"G\",A\nhttp://h/1.ts")
		XCTAssertEqual(ch[0].name, "A")
		XCTAssertEqual(ch[0].group, "G")
	}

	func testEntryWithoutUrlIsDropped() {
		let ch = M3U.parse(sourceId: "s", text: "#EXTINF:-1,Broken\n#EXTINF:-1,Good\nhttp://h/1.ts")
		XCTAssertEqual(ch.map(\.name), ["Good"])
	}

	func testHeaderGuides() {
		XCTAssertEqual(M3U.headerGuides("#EXTM3U x-tvg-url=\"http://a/1.xml, https://b/2.xml.gz\"\n"), ["http://a/1.xml", "https://b/2.xml.gz"])
		XCTAssertEqual(M3U.headerGuides("#EXTM3U url-tvg=http://a/1.xml,http://b/2.xml\n"), ["http://a/1.xml", "http://b/2.xml"])
		XCTAssertEqual(M3U.headerGuides("\u{FEFF}#EXTM3U x-tvg-url=\"HTTP://a/1.xml\""), ["http://a/1.xml"])
		// A playlist must never point the importer at a local file.
		XCTAssertEqual(M3U.headerGuides("#EXTM3U x-tvg-url=\"file:///etc/passwd\""), [])
		XCTAssertEqual(M3U.headerGuides("#EXTINF:-1,A\nhttp://h/1.ts"), [])
	}

	func testBrokenPercentEscapeInHeaderTailDoesNotCrash() {
		XCTAssertEqual(M3U.splitHeaders("http://h/1.ts|Cookie=100%zz").1["Cookie"], "100%zz")
	}

	func testM3uParsesAttributesTitleWithCommaAndHeaderCatchup() {
		let text = """
			#EXTM3U catchup="xc" catchup-days="3"
			#EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" group-title="UK, News",BBC One, London
			http://h/live/u/p/1.ts
			#EXTINF:-1,No Group
			#EXTGRP:Misc
			http://h/live/u/p/2.ts
			"""
		let ch = M3U.parse(sourceId: "s", text: text)
		XCTAssertEqual(ch.count, 2)
		XCTAssertEqual(ch[0].name, "BBC One, London")
		XCTAssertEqual(ch[0].group, "UK, News")
		XCTAssertEqual(ch[0].tvgId, "bbc1.uk")
		XCTAssertEqual(ch[0].catchupDays, 3)
		XCTAssertEqual(ch[1].group, "Misc")
	}

	func testHeaderTailBecomesHeaders() {
		let (url, h) = M3U.splitHeaders("http://a/b.ts|UA=VLC&Referer=http%3A%2F%2Fx")
		XCTAssertEqual(url, "http://a/b.ts")
		XCTAssertEqual(h["User-Agent"], "VLC")
		XCTAssertEqual(h["Referer"], "http://x")
	}

	func testM3uKindsFromPath() {
		XCTAssertEqual(M3U.kindOf(url: "http://h/movie/u/p/1.mp4", tvgType: ""), Channel.kindMovie)
		XCTAssertEqual(M3U.kindOf(url: "http://h/series/u/p/9.mkv", tvgType: ""), Channel.kindEpisode)
		XCTAssertEqual(M3U.kindOf(url: "http://h/live/u/p/2.ts", tvgType: ""), Channel.kindLive)
	}

	// ---- Catch-up ----

	func ch(_ url: String, _ attrs: [String: String]) -> Channel { Channel(sourceId: "s", itemId: "1", name: "C", group: "G", url: url, attrs: attrs) }
	let start: Int64 = 1_760_000_400_000 // 2025-10-09 09:00 UTC

	func testXtreamCatchupKeepsQueryAndHeaders() {
		let url = Catchup.url(ch("http://h/live/u/p/42.ts?token=t|User-Agent=X", ["catchup": "xc"]), start, start + 3_600_000, zone: utc)
		XCTAssertEqual(url, "http://h/timeshift/u/p/60/2025-10-09:09-00/42.ts?token=t|User-Agent=X")
	}

	func testXtreamCatchupUsesTheProvidersClock() {
		let c = ch("http://h/live/u/p/42.ts", ["catchup": "xc", "catchup-timezone": "UTC"])
		XCTAssertEqual(Catchup.url(c, start, start + 1_800_000, zone: TimeZone(identifier: "America/New_York")!), "http://h/timeshift/u/p/30/2025-10-09:09-00/42.ts")
	}

	func testCatchupOffsetShiftsTheArchiveStart() {
		let c = ch("http://h/live/u/p/42.ts", ["catchup": "xc", "catchup-offset": "1"])
		XCTAssertEqual(Catchup.url(c, start, start + 1_800_000, zone: utc), "http://h/timeshift/u/p/30/2025-10-09:08-00/42.ts")
	}

	func testTemplateTokens() {
		let c = ch("http://h/s.m3u8", ["catchup-source": "http://a/{Y}/{m}/{d}/{H}{M}?d={duration}&e={utcend}"])
		// A full URL template replaces the live URL (Kodi catchup="default"); it is never glued onto it.
		XCTAssertEqual(Catchup.url(c, start, start + 1_800_000, zone: utc), "http://a/2025/10/09/0900?d=1800&e=\((start + 1_800_000) / 1000)")
	}

	func testAppendTemplateKeepsLiveUrlAndHeaders() {
		let c = ch("http://h/s.m3u8|User-Agent=X", ["catchup": "append", "catchup-source": "?utc={utc}"])
		XCTAssertEqual(Catchup.url(c, start, start + 60_000, zone: utc), "http://h/s.m3u8?utc=\(start / 1000)|User-Agent=X")
	}

	func testPathStyleAddsTheStreamId() {
		let c = ch("http://h/live/u/p/42.ts", ["catchup": "default", "catchup-source": "http://a/archive"])
		XCTAssertEqual(Catchup.url(c, start, start + 1_800_000, zone: utc), "http://a/archive/42/2025-10-09:09-00/30/")
	}

	func testFlussonicArchive() {
		let c = ch("http://h/ch/index.m3u8", ["catchup-type": "flussonic", "catchup-source": "http://a/ch/123"])
		XCTAssertEqual(Catchup.url(c, start, start + 1_800_000, zone: utc), "http://a/ch/123/20251009090000-30.m3u8")
	}

	func testTemplateCatchupIsAppended() {
		let s: Int64 = 1_000_000_000_000
		let url = Catchup.url(ch("http://h/x.m3u8?t=1", ["catchup-source": "?utc=${start}&lutc=${timestamp}"]), s, s + 60_000, zone: utc, now: 2_000_000_000_000)
		XCTAssertEqual(url, "http://h/x.m3u8?t=1&utc=1000000000&lutc=2000000000")
	}

	func testNoCatchupGivesNil() { XCTAssertNil(Catchup.url(ch("http://h/1.ts", [:]), 0, 60_000)) }

	func testCatchupWindow() {
		let c = ch("http://h/1.ts", ["catchup-days": "2"])
		XCTAssertTrue(Catchup.withinWindow(c, start, now: start + 86_400_000))
		XCTAssertFalse(Catchup.withinWindow(c, start, now: start + 3 * 86_400_000))
		XCTAssertTrue(Catchup.withinWindow(ch("http://h/1.ts", [:]), 0, now: start))
	}

	func testCatchupDaysFromTimeshiftAndDecimals() {
		XCTAssertEqual(ch("u", ["timeshift": "3"]).catchupDays, 3)
		XCTAssertEqual(ch("u", ["catchup-days": "7.0"]).catchupDays, 7)
		XCTAssertEqual(ch("u", ["catchup-days": ""]).catchupDays, 0)
		XCTAssertFalse(ch("u", [:]).hasCatchup)
	}

	// ---- XMLTV ----

	func testXmltvOffsets() {
		let base: Int64 = 1_760_000_400_000 // 20251009090000 UTC
		XCTAssertEqual(Xmltv.parseTime("20251009090000 +0000"), base)
		XCTAssertEqual(Xmltv.parseTime("20251009090000 -0500"), base + 5 * 3_600_000)
		XCTAssertEqual(Xmltv.parseTime("20251009090000 +0530"), base - 5 * 3_600_000 - 1_800_000)
		XCTAssertEqual(Xmltv.parseTime("20251009090000+0100"), base - 3_600_000)
		XCTAssertEqual(Xmltv.parseTime("20251009090000 junk"), base)
		XCTAssertNil(Xmltv.parseTime("20251309090000 +0000"))
		XCTAssertNil(Xmltv.parseTime("20250231090000"))
		XCTAssertNil(Xmltv.parseTime(nil))
		XCTAssertNil(Xmltv.parseTime("2025100909"))
		XCTAssertEqual(Xmltv.parseTime("19700101000000 +0000"), 0)
		XCTAssertEqual(Xmltv.parseTime("19700101000000 +0200"), -7_200_000)
		XCTAssertEqual(Xmltv.parseTime("19700101000000"), 0)
		XCTAssertNil(Xmltv.parseTime("bad"))
		XCTAssertEqual(Xmltv.parseTime("20240229120000 +0000"), 1_709_208_000_000) // leap day
	}

	func testNameKeys() {
		XCTAssertEqual(Xmltv.nameKey("CNN"), Xmltv.nameKey("US| CNN FHD"))
		XCTAssertEqual(Xmltv.nameKey("BBC One"), Xmltv.nameKey("bbc one hd"))
		XCTAssertNotEqual(Xmltv.nameKey("BBC One"), Xmltv.nameKey("BBC Two"))
		XCTAssertNotEqual(Xmltv.nameKey("Sky Sports 1"), Xmltv.nameKey("Sky Sports 2"))
		// A word that merely starts like a country code is not stripped.
		XCTAssertEqual(Xmltv.nameKey("ABC News"), "abcnews")
		XCTAssertEqual(Xmltv.nameKey("BBC One"), Xmltv.nameKey("UK: BBC One HD"))
	}

	func testXmlPullReadsElementsAttributesEntitiesAndCdata() throws {
		let xml = """
			<?xml version="1.0" encoding="UTF-8"?>
			<!DOCTYPE tv SYSTEM "xmltv.dtd">
			<!-- a comment with <tags> -->
			<tv><channel id="a&amp;b"><display-name lang='en'>Tom &amp; Jerry &#233; &#x263A;</display-name><icon src="x"/></channel>
			<programme start="1" channel="c"><title><![CDATA[<Raw> & text]]></title><desc>Line</desc></programme></tv>
			"""
		// Odd chunk sizes: tokens split across reads.
		let p = XmlPull(DataSource(Data(xml.utf8), chunk: 7))
		var seen: [String] = []
		while try p.next() != .eof {
			switch p.event {
			case .start:
				seen.append("<\(p.name)")
				if p.name == "channel" { XCTAssertEqual(p.attrs["id"], "a&b") }
				if p.name == "display-name" { XCTAssertEqual(try p.nextText(), "Tom & Jerry é ☺"); seen.append("/display-name") }
				if p.name == "title" { XCTAssertEqual(try p.nextText(), "<Raw> & text"); seen.append("/title") }
			case .end: seen.append("/\(p.name)")
			default: break
			}
		}
		XCTAssertEqual(seen, ["<tv", "<channel", "<display-name", "/display-name", "<icon", "/icon", "/channel", "<programme", "<title", "/title", "<desc", "/desc", "/programme", "/tv"])
	}

	func testXmlPullCutOffThrows() {
		let p = XmlPull(DataSource(Data("<tv><programme start=\"1".utf8)))
		XCTAssertThrowsError(try { while try p.next() != .eof {} }())
	}

	// ---- JSON stream ----

	func testJsonStreamSkipsNestingAndErrorObjects() throws {
		let body = #"[{"a":"x\"yé","n":5,"f":1.5,"b":true,"z":null,"nest":{"q":[1,{"r":2}]},"list":[1,2]},7,"s",{"a":"😀"}]"#
		var got: [[String: String]] = []
		try JsonStream(DataSource(Data(body.utf8), chunk: 5)).forEachObject { got.append($0) }
		XCTAssertEqual(got.count, 2)
		XCTAssertEqual(got[0], ["a": "x\"yé", "n": "5", "f": "1.5", "b": "true"])
		XCTAssertEqual(got[1]["a"], "😀")
		var none = 0
		try JsonStream(DataSource(Data(#"{"user_info":{"auth":0}}"#.utf8))).forEachObject { _ in none += 1 }
		XCTAssertEqual(none, 0)
	}

	// ---- Xtream ----

	func testServerAddressForms() {
		XCTAssertEqual(Xtream.normalizeServer("h:8080/"), "http://h:8080")
		XCTAssertEqual(Xtream.normalizeServer("http://h:8080/player_api.php"), "http://h:8080")
		XCTAssertEqual(Xtream.normalizeServer("http://h:8080/get.php?username=u&password=p&type=m3u_plus"), "http://h:8080")
		XCTAssertEqual(Xtream.normalizeServer("  https://h/sub/  "), "https://h/sub")
	}

	func testCredentialsFromPanelLinks() {
		func c(_ u: String) -> [String]? { Xtream.credentialsFromUrl(u).map { [$0.server, $0.user, $0.pass] } }
		XCTAssertEqual(c("http://h:8080/get.php?username=u&password=p&type=m3u_plus"), ["http://h:8080", "u", "p"])
		XCTAssertEqual(c("http://h:8080/live/u/p/123.ts"), ["http://h:8080", "u", "p"])
		XCTAssertEqual(c("http://h/u/p/123"), ["http://h", "u", "p"])
		XCTAssertEqual(c("http://h/timeshift/u/p/60/2025-10-09:09-00/1.ts"), ["http://h", "u", "p"])
		XCTAssertEqual(c("http://h/get.php?username=a%20b&password=p"), ["http://h", "a b", "p"])
		// In a path "+" is a plus; the stream URL this app builds round-trips.
		XCTAssertEqual(c("http://h/live/a%20b/p+q/1.ts"), ["http://h", "a b", "p+q"])
		// False matches would show an account that does not exist.
		XCTAssertNil(c("http://h/playlist.m3u"))
		XCTAssertNil(c("http://h/a/b/c/d/123.ts"))
		XCTAssertNil(c("content://media/1"))
		XCTAssertNil(c("http://h/get.php?username=u"))
	}

	func testXtreamListsFromStreamedJson() throws {
		let src = Source(id: "x", type: Source.typeXtream, name: "X", url: "http://h", username: "u s", password: "p")
		var out: [Channel] = []
		try JsonStream(DataSource(Data(#"[{"stream_id":5,"num":42,"name":"X","category_id":"1","epg_channel_id":null,"tv_archive":1,"tv_archive_duration":"3"}]"#.utf8)))
			.forEachObject { out.append(Xtream.live(src, $0, ["1": "News"])) }
		XCTAssertEqual(out[0].url, "http://h/live/u%20s/p/5.ts")
		XCTAssertEqual(out[0].number, "42")
		XCTAssertEqual(out[0].group, "News")
		XCTAssertEqual(out[0].tvgId, "")
		XCTAssertEqual(out[0].catchupDays, 3)
		XCTAssertEqual(Xtream.movie(src, ["stream_id": "9", "name": "M"], [:]).url, "http://h/movie/u%20s/p/9.mp4")
		XCTAssertEqual(Xtream.show(src, ["series_id": "4", "name": "S", "plot": "P"], [:]).attrs["plot"], "P")
	}

	func testEpisodesInListFormAndKeyedBySeason() throws {
		let src = Source(id: "x", type: Source.typeXtream, name: "X", url: "http://h", username: "u", password: "p")
		let show = Channel(sourceId: "x", itemId: "s1", name: "Lost", group: "G", url: "1", kind: Channel.kindSeries)
		let keyed = try Xtream.parseEpisodes(src, show: show, body: Data(#"{"episodes":{"10":[{"id":"b","episode_num":1,"title":"Lost - S10E01"}],"2":[{"id":"a","episode_num":3,"title":"Lost - S02E03 - Pilot","container_extension":"mkv","info":{"plot":"P"}}]}}"#.utf8))
		XCTAssertEqual(keyed.map(\.name), ["Season 2, Episode 3: Pilot", "Season 10, Episode 1"])
		XCTAssertEqual(keyed[0].url, "http://h/series/u/p/a.mkv")
		XCTAssertEqual(keyed[0].attrs["plot"], "P")
		let listed = try Xtream.parseEpisodes(src, show: show, body: Data(#"{"episodes":[[{"id":"a"}],[{"id":"b"},{"id":""}]]}"#.utf8))
		XCTAssertEqual(keyed[0].attrs["season"], "2")
		XCTAssertEqual(keyed[0].attrs["episode_num"], "3")
		XCTAssertEqual(listed[1].attrs["season"], "2")
		XCTAssertEqual(listed[1].attrs["episode_num"], "1")
		XCTAssertEqual(listed.map(\.name), ["Season 1, Episode 1", "Season 2, Episode 1"])
	}

	func testExpiredAccountsSayExpired() throws {
		let now: Int64 = 1_760_000_400_000
		let info = try Xtream.parseAccount(Data(#"{"user_info":{"status":"Active","exp_date":"1759000000","is_trial":"0","active_cons":1,"max_connections":"2"}}"#.utf8), now: now)
		XCTAssertEqual(info[0].1, "Active")
		XCTAssertTrue(info[1].1.hasSuffix("expired"))
		XCTAssertEqual(info[2].1, "No")
		XCTAssertEqual(info[3].1, "1 of 2")
		let never = try Xtream.parseAccount(Data(#"{"user_info":{"status":"Active","exp_date":null}}"#.utf8), now: now)
		XCTAssertEqual(never[1].1, "Never")
	}

	func testXtreamGuideUrlIsEscaped() {
		let s = Source(id: "x", type: Source.typeXtream, name: "X", url: "http://h", username: "a b", password: "p&q")
		XCTAssertEqual(s.effectiveEpgUrl, "http://h/xmltv.php?username=a+b&password=p%26q")
	}

	func testEpisodeTitlesDropRepetition() {
		XCTAssertEqual(Xtream.episodeTitle("#1 Happy Family USA - S01E01", show: "#1 Happy Family USA (2025)"), "")
		XCTAssertEqual(Xtream.episodeTitle("Lost - S01E01 - The Pilot", show: "Lost"), "The Pilot")
		XCTAssertEqual(Xtream.episodeTitle("The Pilot", show: "Lost"), "The Pilot")
	}

	func testStalkerKeepsItsEndpointPath() {
		XCTAssertEqual(Stalker.baseUrl("http://p.tv/stalker_portal/server/load.php"), "http://p.tv/stalker_portal")
		XCTAssertEqual(Stalker.baseUrl("p.tv/portal.php"), "http://p.tv")
		XCTAssertEqual(Stalker.baseUrl("portal.tv:8080/c/"), "http://portal.tv:8080")
	}

	// ---- Audio tracks ----

	func testAudioKeywordsAndRememberedTrack() {
		let names = ["English", "Deutsch Audiodeskription", "Polski"]
		let no = [false, false, false]
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: no, remembered: nil, preferAd: true, keywords: []), 1)
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: no, remembered: nil, preferAd: false, keywords: ["polski", "english"]), 2)
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: no, remembered: "english", preferAd: true, keywords: ["polski"]), 0)
		// A remembered track the stream no longer has falls through to the other rules.
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: no, remembered: "Gone", preferAd: false, keywords: ["polski"]), 2)
		XCTAssertFalse(AudioTracks.matches("Broadcast", "ad"))
		XCTAssertFalse(AudioTracks.matches("", "ad"))
	}

	func testAudioDescriptionMatching() {
		XCTAssertTrue(AudioTracks.matches("eng AD", "ad"))
		XCTAssertFalse(AudioTracks.matches("Radio", "ad"))
		XCTAssertTrue(AudioTracks.matches("Audiodescription-Ton", "audiodescription"))
		XCTAssertTrue(AudioTracks.matches("Deutsch (Hörfilm)", "hörfilm"))
		let names = ["English", "English (Audio Description)"]
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: [false, false], remembered: nil, preferAd: true, keywords: []), 1)
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: [false, false], remembered: "English", preferAd: true, keywords: []), 0)
		XCTAssertEqual(AudioTracks.choose(names: names, describesVideo: [false, false], remembered: nil, preferAd: false, keywords: []), -1)
		// The "describes video" flag wins even when the name says nothing.
		XCTAssertEqual(AudioTracks.choose(names: ["Polish", "x"], describesVideo: [false, true], remembered: nil, preferAd: true, keywords: []), 1)
	}

	// ---- Search ----

	func named(_ n: String...) -> [Channel] { n.enumerated().map { Channel(sourceId: "s", itemId: "\($0.offset)", name: $0.element, group: "G", url: "u\($0.offset)") } }

	// ---- Playback ----

	func testReconnectBudgetMatchesTheDesktop() {
		var now: Int64 = 1_000
		let r = Reconnect { now }
		XCTAssertEqual((0..<6).map { _ in r.next() }, [400, 2000, 4000, 8000, 8000, 8000])
		XCTAssertNil(r.next())
		now += Reconnect.resetMs
		XCTAssertEqual(r.next(), 400)
		r.reset()
		XCTAssertEqual(r.next(), 400)
	}

	func testLiveCushionAndPace() {
		// Under 10 s of history: just the cache.
		XCTAssertEqual(Cushion.liveCushionSeconds(readBytes: 9_000_000, demuxBytes: 1_000_000, playedMs: 5_000, cacheSeconds: 0.5), 0.5)
		// 60 s played on a 0.5 s cache: 1 MB/s demuxed; 5 MB unread = 5 s more.
		let c = Cushion.liveCushionSeconds(readBytes: 65_500_000, demuxBytes: 60_500_000, playedMs: 60_000, cacheSeconds: 0.5)
		XCTAssertEqual(c, 5.5, accuracy: 0.001)
		XCTAssertEqual(Cushion.paceRate(cushion: 2, target: 25, current: 1), Cushion.slowRate)
		XCTAssertEqual(Cushion.paceRate(cushion: 24.9, target: 25, current: Cushion.slowRate), Cushion.slowRate)
		XCTAssertEqual(Cushion.paceRate(cushion: 25, target: 25, current: Cushion.slowRate), 1)
		XCTAssertEqual(Cushion.paceRate(cushion: 24.5, target: 25, current: 1), 1, "no flapping just under the target")
		XCTAssertEqual(Cushion.paceRate(cushion: 23.9, target: 25, current: 1), Cushion.slowRate)
		XCTAssertEqual(Cushion.target(base: 2, max: 30, stalls: 0), 25)
		XCTAssertEqual(Cushion.target(base: 2, max: 30, stalls: 9), 30)
		XCTAssertEqual(Cushion.target(base: 40, max: 30, stalls: 0), 30)
	}

	// ---- Recording ----

	func pes(_ pid: Int, _ ptsSec: Double) -> [UInt8] {
		var p = [UInt8](repeating: 0xFF, count: 188)
		p[0] = 0x47; p[1] = UInt8(0x40 | (pid >> 8)); p[2] = UInt8(pid & 0xFF); p[3] = 0x10
		let pts = Int64(ptsSec * 90_000)
		let h: [UInt8] = [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5,
			UInt8(truncatingIfNeeded: 0x21 | ((pts >> 29) & 0x0E)), UInt8(truncatingIfNeeded: pts >> 22), UInt8(truncatingIfNeeded: ((pts >> 14) & 0xFE) | 1),
			UInt8(truncatingIfNeeded: pts >> 7), UInt8(truncatingIfNeeded: ((pts << 1) & 0xFE) | 1)]
		for (i, b) in h.enumerated() { p[4 + i] = b }
		return p
	}

	func testTsClockMeasuresWhatWasWrittenAcrossOddChunks() {
		let stream = pes(0x100, 10) + pes(0x101, 99) + pes(0x100, 70.5) + pes(0x100, 40)
		let c = TsClock()
		var i = 0
		for n in [5, 200, 1, 300, 1000] { let m = min(n, stream.count - i); c.feed(Data(stream[i..<(i + m)])); i += m }
		XCTAssertEqual(c.durationMs, 60_500, "only the first stream counts; the newest time, not the last packet")
	}

	func testTsClockIgnoresNonTs() {
		let c = TsClock()
		c.feed(Data((0..<5000).map { UInt8($0 % 251) }))
		XCTAssertNil(c.durationMs)
	}

	func testCatchupEndedEarlyRule() {
		XCTAssertTrue(Recording.endedEarly(writtenMs: 1_000_000, expectMs: 1_800_000)) // 18 of 30 minutes
		XCTAssertFalse(Recording.endedEarly(writtenMs: 1_700_000, expectMs: 1_800_000)) // inside 10%
		XCTAssertFalse(Recording.endedEarly(writtenMs: nil, expectMs: 1_800_000)) // not TS: no check
		XCTAssertFalse(Recording.endedEarly(writtenMs: 10, expectMs: 0)) // a movie: no expected length
	}

	func testSchedulePaddingWidensTheWindow() {
		let c = Channel(sourceId: "s", itemId: "1", name: "BBC One", group: "", url: "http://h/1.ts")
		let s = Recording.padded(id: 1, channel: c, title: "News", start: 10_000_000, end: 11_800_000, preMinutes: 5, postMinutes: 10)
		XCTAssertEqual(s.start, 10_000_000 - 300_000)
		XCTAssertEqual(s.end, 11_800_000 + 600_000)
		// Same JSON keys as the Android app.
		let json = String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
		XCTAssertTrue(json.contains("\"ch\":\"s:1\""))
	}

	func testFileNamesAreSafe() {
		let n = Recording.fileName(label: "A/B: C?", at: 0)
		XCTAssertTrue(n.hasPrefix("A_B_ C_ "))
		XCTAssertTrue(n.hasSuffix(".ts"))
		XCTAssertFalse(n.dropLast(3).contains(":"))
	}

	/// The name carries the minute, so two recordings of one channel inside a minute collide.
	func testASecondRecordingInAMinuteGetsItsOwnName() {
		var taken: Set<String> = []
		let first = Recording.freeFileName("BBC One 14 Oct 2026 8-00 PM.ts") { taken.contains($0) }
		XCTAssertEqual(first, "BBC One 14 Oct 2026 8-00 PM.ts")
		taken.insert(first)
		let second = Recording.freeFileName("BBC One 14 Oct 2026 8-00 PM.ts") { taken.contains($0) }
		XCTAssertEqual(second, "BBC One 14 Oct 2026 8-00 PM-2.ts")
		taken.insert(second)
		XCTAssertEqual(Recording.freeFileName("BBC One 14 Oct 2026 8-00 PM.ts") { taken.contains($0) }, "BBC One 14 Oct 2026 8-00 PM-3.ts")
	}

	func stream(_ parts: [String], fail: Bool = false) -> AsyncThrowingStream<Data, Error> {
		AsyncThrowingStream { c in
			for p in parts { c.yield(Data(p.utf8)) }
			if fail { c.finish(throwing: URLError(.networkConnectionLost)) } else { c.finish() }
		}
	}

	func testDownloadCopiesOnceToTheEnd() async {
		var out = ""
		var opens = 0
		let ok = await Recording.copy(open: { opens += 1; return stream(["abc"]) }, write: { out += String(decoding: $0, as: UTF8.self) }, reconnect: false, pauseMs: 0) { false }
		XCTAssertTrue(ok)
		XCTAssertEqual(out, "abc")
		XCTAssertEqual(opens, 1)
	}

	func testRecordingReconnectsAfterADropAndAppends() async {
		var out = ""
		var parts = ["abc", "def"]
		var opens = 0
		let ok = await Recording.copy(open: {
			opens += 1
			if parts.isEmpty { throw URLError(.cannotConnectToHost) }
			return stream([parts.removeFirst()], fail: true)
		}, write: { out += String(decoding: $0, as: UTF8.self) }, reconnect: true, pauseMs: 0, maxMisses: 3) { false }
		XCTAssertTrue(ok)
		XCTAssertEqual(out, "abcdef")
		XCTAssertEqual(opens, 2 + 3) // two good opens, then three misses in a row end it
	}

	func testRecordingStopsWhenDone() async {
		var opens = 0
		let ok = await Recording.copy(open: { opens += 1; return stream(["x"]) }, write: { _ in }, reconnect: true, pauseMs: 0) { true }
		XCTAssertFalse(ok)
		XCTAssertEqual(opens, 0)
	}

	func testRecordingThatNeverConnectsWritesNothing() async {
		var wrote = 0
		let ok = await Recording.copy(open: { throw URLError(.cannotConnectToHost) }, write: { wrote += $0.count }, reconnect: true, pauseMs: 0, maxMisses: 2) { false }
		XCTAssertFalse(ok)
		XCTAssertEqual(wrote, 0)
	}

	func testRecordingClosesReaderBeforeReconnectAndEarlyExit() async {
		var open = false, opens = 0, closes = 0
		let ok = await Recording.copy(open: {
			XCTAssertFalse(open, "Reconnecting must not overlap the previous reader")
			open = true
			opens += 1
			return stream(["x", "y"])
		}, write: { _ in }, close: {
			await Task.yield()
			open = false
			closes += 1
		}, reconnect: true, pauseMs: 0) { opens == 2 }
		XCTAssertTrue(ok)
		XCTAssertEqual(opens, 2)
		XCTAssertEqual(closes, 2)
		XCTAssertFalse(open, "Stopping early must close the transport too")
	}

	func testRecordingTransportClosesFromCancelledTask() async throws {
		let reader = try Recording.Reader("http://127.0.0.1:9/live.ts", headers: [:])
		let closed = expectation(description: "URLSession invalidation completed")
		let task = Task { await reader.close(); closed.fulfill() }
		task.cancel()
		await fulfillment(of: [closed], timeout: 5)
	}

	// ---- Text, updates, subtitles ----

	func testSentences() {
		XCTAssertEqual(Format.sentences(["A", " ", "", "B"]), "A. B")
		XCTAssertEqual(Format.sentences([]), "")
		XCTAssertEqual(Format.sentences(["A, 8:00 p.m.", "Next: B, 9 p.m."]), "A, 8:00 p.m. Next: B, 9 p.m.")
	}

	func testVersionCompare() {
		XCTAssertTrue(Updater.isNewer("0.2.6", "0.2.5"))
		XCTAssertTrue(Updater.isNewer("1.0", "0.99.99"))
		XCTAssertFalse(Updater.isNewer("0.2.5", "0.2.5.0"))
		XCTAssertFalse(Updater.isNewer("", "0.1"))
		XCTAssertTrue(Updater.isNewer("0.10.0", "0.9.3"))
		XCTAssertFalse(Updater.isNewer("0.2.0", "0.2.0"))
		XCTAssertFalse(Updater.isNewer("0.1.9", "0.2"))
	}

	func testSubtitleCues() {
		let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i> &amp;\r\nthere\r\n\r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nSecond\r\n\r\nno timing here\r\n"
		let cues = SubtitleCues.parse(srt)
		XCTAssertEqual(cues, [SubtitleCues.Cue(start: 1000, end: 2500, text: "Hello & there"), SubtitleCues.Cue(start: 2000, end: 4000, text: "Second")])
		XCTAssertNil(SubtitleCues.active(cues, 500))
		XCTAssertEqual(SubtitleCues.active(cues, 1500), 0)
		XCTAssertEqual(SubtitleCues.active(cues, 2200), 1, "the latest-starting cue wins on overlap")
		XCTAssertNil(SubtitleCues.active(cues, 5000))
		XCTAssertEqual(SubtitleCues.started(cues, 5000), 1)
		let vtt = SubtitleCues.parse("WEBVTT\n\n00:01.5 --> 00:02.000 align:start\nShort form")
		XCTAssertEqual(vtt.first?.start, 1500)
	}

	func testChannelNumbers() {
		let list = M3U.parse(sourceId: "s", text: "#EXTINF:-1 tvg-chno=\"101\",BBC\nhttp://h/1\n#EXTINF:-1,ITV\nhttp://h/2\n#EXTINF:-1 tvg-chno=\"7\",Arena\nhttp://h/3")
		XCTAssertEqual(list[0].number, "101")
		XCTAssertEqual(Channel.byNumber(list, "7")?.name, "Arena")
		XCTAssertEqual(Channel.byNumber(list, "2")?.name, "ITV") // no provider number: the 2nd entry
		XCTAssertNil(Channel.byNumber(list, "0"))
		XCTAssertNil(Channel.byNumber(list, "abc"))
		XCTAssertNil(Channel.byNumber(list, "500"))
	}

	func testChannelCacheRoundTripsEveryField() throws {
		let c = Channel(sourceId: "s", itemId: "i", name: "N", group: "G", url: "u", tvgId: "t", logo: "l", attrs: ["catchup": "xc"], kind: Channel.kindMovie)
		let back = try JSONDecoder().decode([Channel].self, from: JSONEncoder().encode([c]))
		XCTAssertEqual(back, [c])
		// The Android cache format reads too.
		let android = try JSONDecoder().decode([Channel].self, from: Data(#"[{"s":"s","i":"1","n":"A","g":"G","u":"http://h/1","k":"live"}]"#.utf8))
		XCTAssertEqual(android[0].key, "s:1")
	}

	func testSourceJsonMatchesAndroid() throws {
		let s = try JSONDecoder().decode([Source].self, from: Data(#"[{"id":"a","type":"xtream","name":"X","url":"http://h","username":"u","password":"p"}]"#.utf8))
		XCTAssertEqual(s[0].mac, "")
		XCTAssertTrue(s[0].isXtream)
		XCTAssertEqual(Source.enc("a b&c/é"), "a+b%26c%2F%C3%A9")
	}
}
