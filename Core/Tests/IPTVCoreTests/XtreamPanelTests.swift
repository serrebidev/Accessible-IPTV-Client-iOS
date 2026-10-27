import XCTest
@testable import IPTVCore

final class XtreamPanelTests: XCTestCase {
	private func source(_ url: String) -> Source {
		Source(id: "x", type: Source.typeXtream, name: "Test", url: url, username: "user", password: "pass")
	}

	// Dispatcharr apps/output/views.py _build_xc_server_info, as served on 2026-10-27.
	private let dispatcharr = Data(#"{"user_info":{"auth":1},"server_info":{"url":"tv.example","server_protocol":"https","port":"443","timezone":"UTC","timestamp_now":1793062775,"time_now":"2026-10-27 00:59:35","process":true}}"#.utf8)
	private let xui = Data(#"{"user_info":{"auth":1},"server_info":{"url":"panel.example","port":"80","https_port":"443","server_protocol":"http","rtmp_port":"8880","timezone":"Europe/London","timestamp_now":1793062775,"time_now":"2026-10-27 00:59:35","process":true}}"#.utf8)

	func testDispatcharrLoginMarksItsLiveChannels() {
		let src = source("http://tv.example")
		let p = Xtream.panel(src, body: dispatcharr, finalURL: nil)
		XCTAssertTrue(p.dispatcharr)
		XCTAssertTrue(Xtream.live(src, ["stream_id": "7", "name": "KCPQ"], [:], p).isDispatcharr)
		XCTAssertFalse(Xtream.panel(src, body: xui, finalURL: nil).dispatcharr)
		XCTAssertFalse(Xtream.live(src, ["stream_id": "7"], [:], nil).isDispatcharr)
	}

	func testSameHostHttpsRedirectBecomesTheStreamBase() {
		let src = source("http://tv.example")
		let final = URL(string: "https://tv.example/player_api.php?username=user&password=pass")
		let p = Xtream.panel(src, body: xui, finalURL: final)
		XCTAssertEqual(p.base, "https://tv.example")
		XCTAssertEqual(Xtream.live(src, ["stream_id": "7"], [:], p).url, "https://tv.example/live/user/pass/7.ts")
		// Another host, or no upgrade to https, keeps the login's own server.
		XCTAssertEqual(Xtream.panel(src, body: xui, finalURL: URL(string: "https://cdn.example/player_api.php")).base, "http://tv.example")
		XCTAssertEqual(Xtream.panel(src, body: xui, finalURL: URL(string: "http://tv.example/player_api.php")).base, "http://tv.example")
	}
}
