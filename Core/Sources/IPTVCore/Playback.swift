import Foundation

/// Prefer Apple's player without probing the provider or rewriting a raw transport-stream URL.
public enum PlaybackBackend {
	case native, vlc

	public static func preferred(for raw: String) -> PlaybackBackend {
		let (plain, headers) = M3U.splitHeaders(raw)
		// AVURLAsset has a public user-agent option, but no general HTTP-header option.
		guard headers.keys.allSatisfy({ $0.lowercased() == "user-agent" }),
			let url = URL(string: plain), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return .vlc }
		// Xtream's extensionless /live/user/password/id endpoints serve MPEG-TS.
		let path = url.pathComponents.filter { $0 != "/" }
		if path.count == 4, path[0].lowercased() == "live", UInt64(path[3]) != nil { return .vlc }
		let compatibility = ["ts", "m2ts", "mts", "mkv", "avi", "flv", "wmv", "asf", "vob", "ogg", "ogv"]
		return compatibility.contains(url.pathExtension.lowercased()) ? .vlc : .native
	}
}

/// User intent survives buffering and system interruptions; a pause must also cancel reconnects.
public struct PlaybackIntent {
	private var wanted = true
	private var interrupted = false
	public init() {}
	public var canPlay: Bool { wanted && !interrupted }
	public mutating func play() { wanted = true }
	public mutating func pause() { wanted = false }
	public mutating func beginInterruption() { interrupted = true }
	public mutating func endInterruption(shouldResume: Bool) -> Bool {
		guard interrupted else { return false }
		interrupted = false
		wanted = wanted && shouldResume
		return canPlay
	}
}

/// The desktop player's live cushion (internal_player.py), for libVLC on iOS too: a live channel
/// opens on a [quickStartSeconds] cache and the rest of the buffer is played as it arrives.
/// Filling never slows playback down (2026-10-17, the desktop's rule): the buffer only grows
/// from what the server hands over ahead of real time, so the rate stays 1.
public enum Cushion {
	public static let quickStartSeconds = 0.5

	/// The buffer to keep: the saved setting, at most the maximum, plus one second per stall
	/// (desktop: base_buffer_seconds + 1 per stall, capped at max_buffer_seconds).
	public static func target(base: Double, max: Double, stalls: Int) -> Double {
		min(max, base + Double(stalls))
	}

	/// The cache an open starts with, in seconds. A first start is quick (half a second of
	/// cache and the cushion fills while playing); a reopen after a stall waits with the
	/// whole saved cushion, because the desktop creates the reopened media with the full
	/// caching value instead of the quick-start one.
	public static func openSeconds(base: Double, max: Double, stalls: Int, reopened: Bool) -> Double {
		if reopened { return target(base: base, max: max, stalls: stalls) }
		return min(target(base: base, max: max, stalls: 0), quickStartSeconds)
	}
}

/// The desktop player's playback-health bookkeeping (internal_player.py), fed once a
/// second by whichever player is running: buffering that follows playback and lasts
/// 10 s is a stall, four buffering events of 1.25 s or more inside a minute are choppy
/// playback, media progress frozen for 10 s (after a fresh 12 s plus cache startup grace) is a stall, a
/// reopened stream with no media after 25 s restarts, and a channel that has not played
/// at all 30 s after it was chosen is given up on. Pure time arithmetic against an
/// injected clock, so the rules are testable without a player.
public struct StallTracker {
	public enum Verdict: Equatable { case none, restart, restartGrown, giveUp }

	public static let prolongedSeconds = 10.0
	public static let eventMinSeconds = 1.25
	public static let choppyWindowSeconds = 60.0
	public static let choppyCount = 4
	public static let cooldownSeconds = 20.0
	public static let noMediaSeconds = 25.0
	public static let firstPlayDeadlineSeconds = 30.0
	public static let frozenSeconds = 10.0
	public static let startupGraceSeconds = 12.0

	private let now: () -> Double
	private var openedAt: Double
	private var preparedAt: Double
	private var played = false
	private var playedThisOpen = false
	private var caching = 0.0
	private var bufferingSince: Double?
	private var events: [Double] = []
	private var lastAdjustAt = -Double.infinity
	private var gaveUp = false

	public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
		self.now = now
		openedAt = now()
		preparedAt = openedAt
	}

	/// A fresh request (a new channel, or the user pressing play again): every clock restarts.
	public mutating func reset() {
		openedAt = now()
		preparedAt = openedAt
		played = false
		playedThisOpen = false
		caching = 0
		bufferingSince = nil
		events = []
		lastAdjustAt = -Double.infinity
		gaveUp = false
	}

	/// A (re)open of the same stream: the no-media clock restarts, the channel's does not.
	public mutating func prepared(caching: Double = 0) {
		preparedAt = now()
		self.caching = max(0, caching)
		playedThisOpen = false
		bufferingSince = nil
		events = []
	}

	/// Playback reached the screen: the first-play deadline is met for good.
	public mutating func playing() {
		played = true
		playedThisOpen = true
		closeEpisode()
	}

	/// One health tick. `frozen` is how long media progress has stood still while the
	/// player claims to be playing (0 while buffering or paused).
	public mutating func tick(buffering isBuffering: Bool, frozen: Double) -> Verdict {
		let t = now()
		if isBuffering {
			if bufferingSince == nil { bufferingSince = t }
		} else {
			closeEpisode()
		}
		if gaveUp { return .none }
		if !played {
			if t - openedAt >= max(Self.firstPlayDeadlineSeconds, caching + Self.startupGraceSeconds + 5) { gaveUp = true; return .giveUp }
			if t - preparedAt >= max(Self.noMediaSeconds, caching + Self.startupGraceSeconds) { return .restart }
			return .none
		}
		if !playedThisOpen {
			if t - preparedAt >= max(Self.noMediaSeconds, caching + Self.startupGraceSeconds) { return .restart }
			return .none
		}
		// VLC can report Playing while it fills the cache; every reopen gets fresh grace.
		guard t - preparedAt >= Self.startupGraceSeconds + caching else { return .none }
		if isBuffering, let since = bufferingSince, t - since >= Self.prolongedSeconds {
			bufferingSince = t
			lastAdjustAt = t
			return .restartGrown
		}
		if frozen >= Self.frozenSeconds, t - lastAdjustAt >= Self.cooldownSeconds {
			lastAdjustAt = t
			return .restartGrown
		}
		events = events.filter { t - $0 < Self.choppyWindowSeconds }
		if events.count >= Self.choppyCount, t - lastAdjustAt >= Self.cooldownSeconds {
			lastAdjustAt = t
			events = []
			return .restartGrown
		}
		return .none
	}

	private mutating func closeEpisode() {
		guard let since = bufferingSince else { return }
		bufferingSince = nil
		if now() - since >= Self.eventMinSeconds { events.append(now()) }
	}
}

/// The desktop player's stream recovery (_schedule_restart): a dropped live stream is
/// reopened after 0.4, 2, 4, 8, 8, 8 s, then given up. A count that sat unused for two
/// minutes starts again, so one bad evening does not use up the whole budget.
public final class Reconnect {
	private let clock: () -> Int64
	private var attempts = 0
	private var last: Int64 = 0

	public init(clock: @escaping () -> Int64) { self.clock = clock }

	/// Delay before the next try in ms, or nil when it is time to give up.
	public func next() -> Int64? {
		let now = clock()
		// attempts, not the clock, says whether there is a count to reset: a first
		// attempt at clock 0 used to leave last at the "never attempted" sentinel.
		if attempts > 0 && now - last >= Reconnect.resetMs { attempts = 0 }
		if attempts >= Reconnect.max { return nil }
		attempts += 1
		last = now
		return Reconnect.delayMs(attempts)
	}

	public func reset() { attempts = 0; last = 0 }

	public static let max = 6
	public static let resetMs: Int64 = 120_000
	public static func delayMs(_ attempt: Int) -> Int64 { attempt <= 1 ? 400 : min(Int64(1000) << Int64(attempt - 1), 8000) }
}

/// How much programme an MPEG-TS stream holds, read from PES timestamps as the bytes go by.
/// The desktop reads ffmpeg's "time=" line for the same check. Only the first stream that
/// carries a PTS is followed. Not TS (an MP4) = [durationMs] nil.
public final class TsClock {
	private var packet = [UInt8](repeating: 0, count: 188)
	private var fill = 0
	private var pid = -1
	private var first: Int64 = -1
	private var last: Int64 = -1

	public init() {}

	/// Milliseconds between the first and last timestamp seen, or nil when none were.
	public var durationMs: Int64? { first < 0 ? nil : (last - first) / 90 }

	public func feed(_ data: Data) {
		data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			let b = raw.bindMemory(to: UInt8.self)
			var i = 0
			let end = b.count
			while i < end {
				if fill == 0 && b[i] != 0x47 { i += 1; continue }
				let n = min(188 - fill, end - i)
				for k in 0..<n { packet[fill + k] = b[i + k] }
				fill += n
				i += n
				if fill == 188 { parsePacket(); fill = 0 }
			}
		}
	}

	private func parsePacket() {
		if Int(packet[1]) & 0x40 == 0 { return } // not the start of a PES packet
		let p = (Int(packet[1]) & 0x1F) << 8 | Int(packet[2])
		let afc = (Int(packet[3]) >> 4) & 3
		var o = 4 + (afc & 2 != 0 ? 1 + Int(packet[4]) : 0)
		if o + 14 > 188 { return }
		if packet[o] != 0 || packet[o + 1] != 0 || packet[o + 2] != 1 { return }
		if Int(packet[o + 7]) & 0x80 == 0 { return } // no PTS
		if pid >= 0 && p != pid { return }
		o += 9
		// ponytail: no 33-bit wrap handling; a wrap (every 26.5 h) mid-download reads as short and costs one retry.
		let pts = (Int64(packet[o]) >> 1 & 7) << 30
			| Int64(packet[o + 1]) << 22
			| (Int64(packet[o + 2]) >> 1) << 15
			| Int64(packet[o + 3]) << 7
			| Int64(packet[o + 4]) >> 1
		pid = p
		if first < 0 { first = pts }
		if pts > last { last = pts }
	}
}
