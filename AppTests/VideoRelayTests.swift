import AVFoundation
import CoreVideo
import XCTest
import VLCKit
@testable import AccessibleIPTV

/// Runs on the iOS simulator against the bundled synthetic MPEG-2/MP2 transport stream.
final class VideoRelayTests: XCTestCase {
	@MainActor
	func testIncompatibleVideoBecomesDecodableNativeHLS() async throws {
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let source = VLCMediaPlayer()
		source.media = VLCMedia(url: fixture)
		source.play()
		defer { PlaybackTeardown.stop(source) }
		let deadline = Date().addingTimeInterval(15)
		while source.videoTracks.isEmpty || source.audioTracks.isEmpty {
			guard Date() < deadline else { XCTFail("VLC did not discover MPEG-2 and MP2 tracks"); return }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		let tracks = [try XCTUnwrap(source.videoTracks.first).trackId, try XCTUnwrap(source.audioTracks.first).trackId]
		PlaybackTeardown.stop(source)
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
		let relay = VideoRelay()
		defer { relay.stop() }
		let url: URL = try await withCheckedThrowingContinuation { continuation in
			relay.start(source: fixture.absoluteString, tracks: tracks, seconds: 0, live: false) { continuation.resume(with: $0) }
		}
		let (manifest, response) = try await URLSession.shared.data(from: url)
		XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
		XCTAssertTrue(String(decoding: manifest, as: UTF8.self).hasPrefix("#EXTM3U"))
		let item = AVPlayerItem(url: url)
		item.preferredForwardBufferDuration = 1
		let video = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
		item.add(video)
		let native = AVPlayer(playerItem: item)
		defer { native.pause(); native.replaceCurrentItem(with: nil) }
		native.play()
		let decodeDeadline = Date().addingTimeInterval(25)
		while Date() < decodeDeadline {
			if video.copyPixelBuffer(forItemTime: native.currentTime(), itemTimeForDisplay: nil) != nil { return }
			if let error = item.error { throw error }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		XCTFail("Converted HLS produced no decoded video frame")
	}
}
