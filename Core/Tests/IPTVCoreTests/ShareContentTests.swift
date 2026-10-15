import Foundation
import XCTest
@testable import IPTVCore

final class ShareContentTests: XCTestCase {
	private func channel(_ id: String = "1", _ name: String = "BBC One", source: String = "local-source", group: String = "News", tvgId: String = "bbc.one", kind: String = Channel.kindLive, url: String = "https://host/USER/PASS/42.ts", attrs: [String: String] = [:]) -> Channel {
		Channel(sourceId: source, itemId: id, name: name, group: group, url: url, tvgId: tvgId, attrs: attrs, kind: kind)
	}

	func testPayloadContainsOnlySafePublicMetadata() throws {
		let content = try XCTUnwrap(ShareContent(channel: channel(group: "https://USER:PASS@host/category", tvgId: "https://host/USER/PASS")))
		let data = try JSONEncoder().encode(content)
		let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
		XCTAssertEqual(fields, ["name": "BBC One", "group": "", "kind": "live", "tvgId": ""])
		XCTAssertFalse(content.identifier.contains("PASS"))
		XCTAssertEqual(try JSONDecoder().decode(ShareContent.self, from: data), content)
		XCTAssertTrue(content.isValid)
	}

	func testUnnamedPlaylistCredentialsAndUnsupportedContentStayLocal() {
		let unnamed = M3U.parse(sourceId: "s", text: "#EXTM3U\n#EXTINF:-1,\nhttp://host/live/USER/PASS/42.ts")[0]
		XCTAssertNil(ShareContent(channel: unnamed))
		XCTAssertNil(ShareContent(channel: channel("1", " \n\t")))
		for kind in [Channel.kindSeries, Channel.kindEpisode, "unknown"] {
			XCTAssertNil(ShareContent(channel: channel(kind: kind)))
		}
		XCTAssertNil(ShareContent(channel: channel(url: "file:///private/recording.ts")))
	}

	func testIdentityIgnoresProviderKeysButSeparatesGroupAndKind() throws {
		let content = try XCTUnwrap(ShareContent(channel: channel()))
		let otherProvider = try XCTUnwrap(ShareContent(channel: channel("99", source: "other-source", url: "https://another/LOGIN/SECRET/99.ts")))
		XCTAssertEqual(content.identifier, otherProvider.identifier)
		XCTAssertNotEqual(content.identifier, ShareContent(channel: channel(group: "Regional"))?.identifier)
		XCTAssertNotEqual(content.identifier, ShareContent(channel: channel(kind: Channel.kindMovie))?.identifier)
		let remote = try JSONDecoder().decode(ShareContent.self, from: JSONEncoder().encode(content))
		XCTAssertEqual(remote.identifier, content.identifier)
	}

	func testExactNamesNormalizeCaseAndCanonicalUnicodeWithoutFuzzyMatches() throws {
		let content = try XCTUnwrap(ShareContent(channel: channel("1", " CAFÉ ")))
		let channels = [channel("2", "cafe\u{301}"), channel("3", "Café HD"), channel("4", "Other", tvgId: "bbc.one"), channel("5", "Café", kind: Channel.kindMovie)]
		XCTAssertEqual(content.matches(in: channels).map(\.itemId), ["2"])
		XCTAssertTrue(content.matches(in: [channel("3", "Café HD")]).isEmpty)
	}

	func testPreferencesRetainAmbiguityAndFallBackAcrossProviders() throws {
		let content = try XCTUnwrap(ShareContent(channel: channel()))
		let channels = [channel("2", group: "Other"), channel("3"), channel("4"), channel("5", tvgId: "different")]
		XCTAssertEqual(content.matches(in: channels).map(\.itemId), ["3", "4"])
		XCTAssertEqual(content.matches(in: [channel("2", group: "Other"), channel("5", tvgId: "different")]).map(\.itemId), ["2"])
		XCTAssertEqual(content.matches(in: [channel("6", group: "Local", tvgId: "local-id"), channel("7", group: "Local", tvgId: "another-id")]).map(\.itemId), ["6", "7"])
	}

	func testUntrustedDescriptorsCannotResolveUnsafeOrUnknownContent() throws {
		let payloads = [
			["name": "https://host/USER/PASS", "group": "News", "kind": "live", "tvgId": "bbc.one"],
			["name": " \n", "group": "News", "kind": "live", "tvgId": "bbc.one"],
			["name": "BBC One", "group": "https://host/PASS", "kind": "live", "tvgId": "bbc.one"],
			["name": "BBC One", "group": "News", "kind": "live", "tvgId": "https://host/PASS"],
			["name": "BBC One", "group": "News", "kind": "episode", "tvgId": "bbc.one"],
			["name": "BBC One", "group": "News", "kind": "unknown", "tvgId": "bbc.one"]
		]
		for payload in payloads {
			let content = try JSONDecoder().decode(ShareContent.self, from: JSONSerialization.data(withJSONObject: payload))
			XCTAssertFalse(content.isValid)
			XCTAssertTrue(content.matches(in: [channel()]).isEmpty)
		}
		XCTAssertThrowsError(try JSONDecoder().decode(ShareContent.self, from: Data("{}".utf8)))
	}

	func testArchiveRequiresAValidLiveRangeAndParticipatesInIdentity() throws {
		let live = try XCTUnwrap(ShareContent(channel: channel()))
		let archive = try XCTUnwrap(ShareContent(channel: channel(), archiveStart: 100, archiveStop: 200))
		XCTAssertEqual(archive.archiveStart, 100)
		XCTAssertEqual(archive.archiveStop, 200)
		XCTAssertTrue(archive.isValid)
		XCTAssertNotEqual(archive.identifier, live.identifier)
		XCTAssertNotEqual(archive.identifier, ShareContent(channel: channel(), archiveStart: 100, archiveStop: 201)?.identifier)
		XCTAssertEqual(archive.matches(in: [channel()]).count, 1)
		XCTAssertNil(ShareContent(channel: channel(), archiveStart: 100))
		XCTAssertNil(ShareContent(channel: channel(), archiveStop: 200))
		XCTAssertNil(ShareContent(channel: channel(), archiveStart: 0, archiveStop: 200))
		XCTAssertNil(ShareContent(channel: channel(), archiveStart: 200, archiveStop: 100))
		XCTAssertNil(ShareContent(channel: channel(kind: Channel.kindMovie), archiveStart: 100, archiveStop: 200))
		let data = try JSONEncoder().encode(archive)
		XCTAssertEqual(try JSONDecoder().decode(ShareContent.self, from: data), archive)
	}

	func testEpisodesResolveBySeriesAndNumbersAcrossLocalizedTitles() throws {
		let content = try XCTUnwrap(ShareContent(channel: channel("1", "Season 1 Episode 2", group: "Café", kind: Channel.kindEpisode, attrs: ["season": "1", "episode_num": "2"])))
		let channels = [
			channel("2", "Épisode 2", source: "other", group: "CAFE\u{301}", kind: Channel.kindEpisode, attrs: ["season": "1", "episode_num": "2"]),
			channel("3", "Same title", group: "Other show", kind: Channel.kindEpisode, attrs: ["season": "1", "episode_num": "2"]),
			channel("4", "Season 1 Episode 2", group: "Café", kind: Channel.kindEpisode, attrs: ["season": "1", "episode_num": "3"])
		]
		XCTAssertEqual(content.season, 1)
		XCTAssertEqual(content.episode, 2)
		XCTAssertEqual(content.matches(in: channels).map(\.itemId), ["2"])
		XCTAssertEqual(content.matches(in: [channels[0], channels[0]]).count, 2)
		XCTAssertNil(ShareContent(channel: channel(kind: Channel.kindEpisode, attrs: ["season": "0", "episode_num": "2"])))
		XCTAssertNil(ShareContent(channel: channel(group: "", kind: Channel.kindEpisode, attrs: ["season": "1", "episode_num": "2"])))
		let data = try JSONEncoder().encode(content)
		XCTAssertEqual(try JSONDecoder().decode(ShareContent.self, from: data), content)
	}

	func testArchiveBoundsProtectCatchupArithmeticForLocalAndDecodedContent() throws {
		let invalid: [(Int64, Int64)] = [
			(Int64.max - 1, Int64.max),
			(4_102_444_800_000, 4_102_444_800_001),
			(1, 604_800_002)
		]
		for (start, stop) in invalid {
			XCTAssertNil(ShareContent(channel: channel(), archiveStart: start, archiveStop: stop))
			let json = "{\"name\":\"BBC One\",\"group\":\"News\",\"kind\":\"live\",\"tvgId\":\"bbc.one\",\"archiveStart\":\(start),\"archiveStop\":\(stop)}"
			let decoded = try JSONDecoder().decode(ShareContent.self, from: Data(json.utf8))
			XCTAssertFalse(decoded.isValid)
			XCTAssertTrue(decoded.matches(in: [channel()]).isEmpty)
		}
		XCTAssertNotNil(ShareContent(channel: channel(), archiveStart: 1, archiveStop: 604_800_001))
		XCTAssertNotNil(ShareContent(channel: channel(), archiveStart: 4_102_444_799_999, archiveStop: 4_102_444_800_000))
	}

	func testDecodedArchiveAndEpisodeRangesAreValidated() throws {
		let base: [String: Any] = ["name": "BBC One", "group": "News", "kind": "live", "tvgId": "bbc.one"]
		let invalid: [[String: Any]] = [
			["archiveStart": 100], ["archiveStart": 200, "archiveStop": 100],
			["archiveStart": -1, "archiveStop": 100], ["season": 1, "episode": 2],
			["kind": "movie", "archiveStart": 100, "archiveStop": 200],
			["kind": "episode", "season": 0, "episode": 2],
			["kind": "episode", "season": 1],
			["kind": "episode", "season": 1, "episode": 2, "group": ""]
		]
		for extra in invalid {
			let data = try JSONSerialization.data(withJSONObject: base.merging(extra) { _, new in new })
			let content = try JSONDecoder().decode(ShareContent.self, from: data)
			XCTAssertFalse(content.isValid)
			XCTAssertTrue(content.matches(in: [channel()]).isEmpty)
		}
	}
}
