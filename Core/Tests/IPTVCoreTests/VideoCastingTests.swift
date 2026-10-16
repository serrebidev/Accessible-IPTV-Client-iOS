import XCTest
@testable import IPTVCore

final class VideoCastingTests: XCTestCase {
	func testRelayServesOnlyGeneratedFilesBehindItsToken() {
		XCTAssertEqual(VideoCasting.file(for: "/secret/index.m3u8", token: "secret"), "index.m3u8")
		XCTAssertEqual(VideoCasting.file(for: "/secret/playlist-0-12.ts", token: "secret"), "playlist-0-12.ts")
		for path in ["/other/index.m3u8", "/secret/../password.ts", "/secret/%2e%2e/password.ts", "/secret/.hidden.ts", "/secret/password.txt", "/secret/folder/file.ts"] {
			XCTAssertNil(VideoCasting.file(for: path, token: "secret"), path)
		}
	}

	func testOutputUsesRealTrackIdentifiersAndBoundedHLS() throws {
		let output = try VideoCasting.output(directory: "/tmp/session", baseURL: "http://192.168.1.2:1234/secret", tracks: ["video/0", "audio/1"])
		XCTAssertTrue(output.contains("variants=\"{video/0,audio/1}\""))
		XCTAssertTrue(output.contains("codec=h264_videotoolbox"))
		XCTAssertTrue(output.contains("codec=aac"))
		XCTAssertTrue(output.contains("samplerate=48000}:transcode{vcodec=h264"))
		XCTAssertTrue(output.contains("num-seg=6"))
		XCTAssertTrue(output.contains("seg-type=ts"))
		XCTAssertThrowsError(try VideoCasting.output(directory: "/tmp", baseURL: "http://host", tracks: []))
		XCTAssertThrowsError(try VideoCasting.output(directory: "/tmp", baseURL: "http://host", tracks: ["video/0\"},dst=evil"]))
	}

	func testIncompleteManifestDoesNotReplaceLastGoodResponse() {
		XCTAssertFalse(VideoCasting.completeManifest(Data()))
		XCTAssertFalse(VideoCasting.completeManifest(Data("#EXTM3U\n#EXTINF:2,\n".utf8)))
		let valid = Data("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXTINF:2,\nplaylist-0-1.ts\n".utf8)
		XCTAssertTrue(VideoCasting.completeManifest(valid))
		XCTAssertFalse(String(decoding: VideoCasting.liveManifest(valid), as: UTF8.self).contains("PLAYLIST-TYPE"))
	}

	func testMasterReferencesOnlyExistingRenditionGroups() {
		let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=2500000,VIDEO=\"video\",AUDIO=\"audio\",SUBTITLES=\"subtitles\"\nvideo.m3u8\n"
		let normalized = String(decoding: VideoCasting.liveManifest(Data(master.utf8)), as: UTF8.self)
		XCTAssertTrue(normalized.contains(",AUDIO=\"audio\""))
		XCTAssertFalse(normalized.contains(",VIDEO="))
		XCTAssertFalse(normalized.contains(",SUBTITLES="))
	}
}
