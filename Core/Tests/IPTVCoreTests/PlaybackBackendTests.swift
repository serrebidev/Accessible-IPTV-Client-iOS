import XCTest
@testable import IPTVCore

final class PlaybackBackendTests: XCTestCase {
	func testNativeFormatsAndExtensionlessStreams() {
		for url in ["https://tv.test/live.M3U8?token=1", "https://tv.test/movie.mp4", "file:///movie.mov", "https://tv.test/play/123"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: url), .native, url)
		}
	}

	func testTransportStreamsUseAether() {
		for url in ["https://tv.test/live/user/pass/1.ts", "https://tv.test/live/user/pass/123", "file:///recording.ts"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: url), .aether, url)
		}
	}

	func testCompatibilityFormatsStayOnVlc() {
		for url in ["https://tv.test/movie.mkv", "https://tv.test/movie.avi"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: url), .vlc, url)
		}
	}

	func testRequiredHeadersNeverDisappearInNativePlayback() {
		XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/a.m3u8|User-Agent=IPTV"), .native)
		for header in ["Referer=https%3A%2F%2Ftv.test", "Cookie=session%3Dsecret", "Authorization=Bearer%20secret"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/a.m3u8|\(header)"), .vlc)
		}
	}

	func testLiveTransportStreamsReconnectInPlace() {
		for raw in ["https://tv.test/live/user/pass/123", "https://tv.test/live/user/pass/1.ts", "http://tv.test/proxy/ts/stream/abc.TS"] {
			let options = StreamOptions.network(URL(string: raw)!, live: true, cacheMs: 500)
			XCTAssertTrue(options.contains(":http-continuous=1"), raw)
			XCTAssertTrue(options.contains(":network-caching=500"), raw)
		}
	}

	func testContinuousNeverAppliesToFilesHlsOrUnknownStreams() {
		let cases: [(String, Bool)] = [("https://tv.test/movie/user/pass/9.ts", false), ("https://tv.test/a.m3u8", true),
			("https://tv.test/play/123", true), ("https://tv.test/movie.mkv", false)]
		for (raw, live) in cases {
			XCTAssertFalse(StreamOptions.network(URL(string: raw)!, live: live, cacheMs: 500).contains(":http-continuous=1"), raw)
		}
	}

	func testForcedBackendOverridesRouting() {
		PlaybackBackend.forced = .vlc
		defer { PlaybackBackend.forced = nil }
		XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/live/video.ts"), .vlc)
		XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/movie.m3u8"), .vlc)
	}

	func testHlsDelayKeepsVlcFloorAndFollowsALargerCushion() {
		let hls = URL(string: "https://tv.test/live.m3u8?token=1")!
		XCTAssertTrue(StreamOptions.network(hls, live: true, cacheMs: 500).contains(":adaptive-livedelay=15000"))
		let grown = StreamOptions.network(hls, live: true, cacheMs: 20_000)
		XCTAssertTrue(grown.contains(":adaptive-livedelay=20000"))
		XCTAssertTrue(grown.contains(":adaptive-maxbuffer=40000"))
	}
}
