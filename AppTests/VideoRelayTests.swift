import AVFoundation
import CoreVideo
import XCTest
import SwiftVLC
@testable import AccessibleIPTV

/// Runs on the iOS simulator against the bundled synthetic MPEG-2/MP2 transport stream.
final class VideoRelayTests: XCTestCase {
	/// Decodes without drawing or sound, like the simulator run needs.
	private static let headless = try! VLCInstance(arguments: VLCInstance.defaultArguments + ["--vout=dummy", "--aout=dummy"],
		appleAudioSessionPolicy: .applicationManaged)

	@MainActor
	func testIncompatibleVideoBecomesDecodableNativeHLS() async throws {
		try await assertDecodedVideo(subtitles: false)
	}

	@MainActor
	func testSelectedSubtitleStillProducesNativeVideo() async throws {
		try await assertDecodedVideo(subtitles: true)
	}

	@MainActor
	private func assertDecodedVideo(subtitles: Bool) async throws {
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let subtitleFile = subtitles ? Bundle(for: Self.self).url(forResource: "captions", withExtension: "srt") : nil
		let source = Player(instance: Self.headless)
		let sourceMedia = try Media(url: fixture)
		if let subtitleFile { sourceMedia.addOption(":sub-file=\(subtitleFile.path)") }
		PlaybackTeardown.play(source, sourceMedia)
		defer { PlaybackTeardown.stop(source) }
		// CI runners are shared and loaded: real transcoding needs more room here than on a phone.
		let deadline = Date().addingTimeInterval(45)
		while source.videoTracks.isEmpty || source.audioTracks.isEmpty || subtitles && source.subtitleTracks.isEmpty {
			guard Date() < deadline else { XCTFail("VLC did not discover MPEG-2 and MP2 tracks"); return }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		let tracks = [try XCTUnwrap(source.videoTracks.first).id, try XCTUnwrap(source.audioTracks.first).id]
		let subtitleID = subtitles ? source.subtitleTracks.first?.id : nil
		PlaybackTeardown.stop(source)
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
		let relay = VideoRelay()
		relay.firstManifestDeadline = 120
		defer { relay.stop() }
		let url: URL = try await withCheckedThrowingContinuation { continuation in
			relay.start(source: fixture.absoluteString, tracks: tracks, seconds: 0, subtitleID: subtitleID,
				subtitleFile: subtitleFile, live: false) { continuation.resume(with: $0) }
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
		let decodeDeadline = Date().addingTimeInterval(60)
		while Date() < decodeDeadline {
			if video.copyPixelBuffer(forItemTime: native.currentTime(), itemTimeForDisplay: nil) != nil { return }
			if let error = item.error { throw error }
			try await Task.sleep(nanoseconds: 200_000_000)
		}
		XCTFail("Converted HLS produced no decoded video frame")
	}

	@MainActor
	func testImmediateStopCancelsQueuedPlayback() async throws {
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let source = Player(instance: Self.headless)
		for _ in 0..<3 {
			PlaybackTeardown.play(source, try Media(url: fixture))
			PlaybackTeardown.stop(source)
			let stopped = await PlaybackTeardown.ready()
			XCTAssertTrue(stopped)
			// A bare play (a lock-screen Play) must not reopen the stopped media.
			PlaybackTeardown.play(source)
			try await Task.sleep(nanoseconds: 200_000_000)
			XCTAssertFalse(source.isPlaying)
			XCTAssertEqual(source.state, .stopped)
		}
	}

	@MainActor
	func testNaturalEndDoesNotCompleteTheNextTeardown() async throws {
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let source = Player(instance: Self.headless)
		let media = try Media(url: fixture)
		media.addOption(":stop-time=1")
		PlaybackTeardown.play(source, media)
		defer { PlaybackTeardown.stop(source) }
		var active = false
		let deadline = Date().addingTimeInterval(45)
		while Date() < deadline {
			if source.state != .stopped { active = true }
			if active, source.state == .stopped { break }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		guard active, source.state == .stopped else { XCTFail("Source did not reach natural EOF"); return }
		PlaybackTeardown.play(source)
		PlaybackTeardown.stop(source)
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
		XCTAssertFalse(source.isPlaying)
		XCTAssertEqual(source.state, .stopped)
	}
}
