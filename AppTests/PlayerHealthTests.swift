import Combine
import IPTVCore
import XCTest
@testable import AccessibleIPTV

final class PlayerHealthTests: XCTestCase {
	@MainActor
	func testVLCCompletionAtOneAllowsTheNextBufferingEpisode() async {
		let controller = PlayerController(request: PlayRequest(url: "https://example.test/live.ts", title: "Test",
			channelKey: "test", catchup: false, channel: nil, archiveStart: nil, archiveStop: nil))
		let episodes = expectation(description: "Both buffering episodes are announced")
		episodes.expectedFulfillmentCount = 2
		let subscription = controller.$status.dropFirst().sink { status in
			if status == L("buffering") { episodes.fulfill() }
		}
		controller.vlcBuffering(0)
		controller.vlcBuffering(1)
		controller.vlcBuffering(0)
		await fulfillment(of: [episodes], timeout: 3)
		withExtendedLifetime(subscription) {}
	}

	@MainActor
	func testHealthyLiveVLCPlaybackDoesNotReopenAfterTenSeconds() async throws {
		PlaybackBackend.forced = .vlc
		defer { PlaybackBackend.forced = nil }
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let channel = Channel(sourceId: "test", itemId: "1", name: "Test", group: "", url: fixture.absoluteString)
		let controller = PlayerController(request: PlayRequest(url: fixture.absoluteString, title: "Test",
			channelKey: channel.key, catchup: false, channel: channel, archiveStart: nil, archiveStop: nil))
		controller.start()
		defer { controller.close() }
		let deadline = Date().addingTimeInterval(20)
		while !controller.sharedPlaybackReady {
			guard Date() < deadline else { XCTFail("VLC never completed buffering"); return }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		let media = try XCTUnwrap(controller.player.currentMedia)
		// A redundant system Play command must not start a new no-media deadline.
		controller.resume()
		let until = Date().addingTimeInterval(28)
		while Date() < until {
			XCTAssertTrue(controller.player.currentMedia === media, "Healthy live playback was reopened")
			XCTAssertNotEqual(controller.status, L("reconnecting"))
			try await Task.sleep(nanoseconds: 200_000_000)
		}
	}
}
