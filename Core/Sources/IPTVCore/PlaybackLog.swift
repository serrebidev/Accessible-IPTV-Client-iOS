import Foundation

/// The last playback events (buffering spells, player statistics, reconnects, closes), kept in
/// memory so a stall can be copied from Settings and sent in. Lines outlive the player screen;
/// nothing is written to disk. Stream URLs carry credentials and are never logged.
public final class PlaybackLog: @unchecked Sendable {
	public static let shared = PlaybackLog()
	public static let limit = 400

	private let lock = NSLock()
	private var lines: [String] = []
	private let clock: () -> Date
	// UTC with milliseconds, so lines line up with the server's logs.
	private static let stamp: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

	public func add(_ line: String) {
		let stamped = "\(Self.stamp.string(from: clock())) \(line)"
		lock.lock(); defer { lock.unlock() }
		lines.append(stamped)
		if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
	}

	public var text: String {
		lock.lock(); defer { lock.unlock() }
		return lines.joined(separator: "\n")
	}
}

/// libVLC's cumulative counters (SwiftVLC MediaStatistics) as plain numbers, so the
/// per-interval line is testable without a player.
public struct PlaybackStats: Equatable {
	public var readBytes: UInt64 = 0
	public var inputKbps: Float = 0
	public var corrupted: UInt64 = 0
	public var discontinuities: UInt64 = 0
	public var decodedVideo: UInt64 = 0
	public var shownPictures: UInt64 = 0
	public var latePictures: UInt64 = 0
	public var lostPictures: UInt64 = 0
	public var playedAudio: UInt64 = 0
	public var lostAudio: UInt64 = 0

	public init() {}

	/// What changed since [old], over [seconds]. A reopened stream restarts libVLC's
	/// counters, so a counter below its old value counts from zero.
	public func line(since old: PlaybackStats, seconds: Double) -> String {
		func d(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : new }
		let mbps = seconds > 0 ? Double(d(readBytes, old.readBytes)) * 8 / seconds / 1_000_000 : 0
		return String(format: "stats %.0f s: received %.2f Mbps, input %.0f kbps, corrupted +%llu, discontinuities +%llu, "
			+ "video decoded +%llu shown +%llu late +%llu lost +%llu, audio played +%llu lost +%llu",
			seconds, mbps, inputKbps, d(corrupted, old.corrupted), d(discontinuities, old.discontinuities),
			d(decodedVideo, old.decodedVideo), d(shownPictures, old.shownPictures), d(latePictures, old.latePictures),
			d(lostPictures, old.lostPictures), d(playedAudio, old.playedAudio), d(lostAudio, old.lostAudio))
	}
}
