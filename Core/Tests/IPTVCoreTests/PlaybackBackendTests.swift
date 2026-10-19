import XCTest
@testable import IPTVCore

final class PlaybackBackendTests: XCTestCase {
	func testNativeFormatsAndExtensionlessStreams() {
		for url in ["https://tv.test/live.M3U8?token=1", "https://tv.test/movie.mp4", "file:///movie.mov", "https://tv.test/play/123"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: url), .native, url)
		}
	}

	func testTransportStreamsAndCompatibilityFormatsStayUnchanged() {
		for url in ["https://tv.test/live/user/pass/1.ts", "https://tv.test/live/user/pass/123", "file:///recording.ts", "https://tv.test/movie.mkv", "https://tv.test/movie.avi"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: url), .vlc, url)
		}
	}

	func testRequiredHeadersNeverDisappearInNativePlayback() {
		XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/a.m3u8|User-Agent=IPTV"), .native)
		for header in ["Referer=https%3A%2F%2Ftv.test", "Cookie=session%3Dsecret", "Authorization=Bearer%20secret"] {
			XCTAssertEqual(PlaybackBackend.preferred(for: "https://tv.test/a.m3u8|\(header)"), .vlc)
		}
	}
}
