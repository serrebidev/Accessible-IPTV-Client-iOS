import Foundation

/// Prefer Apple's player without probing the provider or rewriting a raw transport-stream URL.
public enum PlaybackBackend {
	case native, vlc

	public static func preferred(for raw: String) -> PlaybackBackend {
		let (plain, headers) = M3U.splitHeaders(raw)
		// AVURLAsset has a public user-agent option, but no general HTTP-header option.
		guard headers.keys.allSatisfy({ $0.lowercased() == "user-agent" }),
			let url = URL(string: plain), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return .vlc }
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
/// opens on a [quickStartSeconds] cache, then plays at [slowRate] until the full cushion is
/// held locally. Live TV arrives at real time, so slower playback is the only way it grows;
/// libVLC keeps reading at network speed and the unplayed bytes pile up in its stream cache.
public enum Cushion {
	public static let quickStartSeconds = 0.5
	// ponytail: fixed 5% slower (pitch kept by VLC's scaletempo); 4 s of cushion takes 80 s.
	public static let slowRate: Float = 0.95
	/// The cushion grows to at least this, whatever buffer is saved.
	public static let liveCushionSeconds = 25.0

	/// Seconds of live media held locally: VLC's cache plus bytes read but not yet demuxed.
	/// The byte rate comes from what was demuxed over the time played. Under 10 s of history
	/// the rate is noise: just the cache, so pacing keeps building.
	public static func liveCushionSeconds(readBytes: UInt64, demuxBytes: UInt64, playedMs: Int64, cacheSeconds: Double) -> Double {
		let span = Double(playedMs) / 1000 + cacheSeconds
		if playedMs < 10_000 || demuxBytes == 0 || span <= 0 { return cacheSeconds }
		let rate = Double(demuxBytes) / span
		return cacheSeconds + Double(readBytes > demuxBytes ? readBytes - demuxBytes : 0) / rate
	}

	/// [slowRate] while the cushion is short of [target], 1 once full; slow again only a
	/// second below target, so the rate does not flip back and forth around it.
	public static func paceRate(cushion: Double, target: Double, current: Float) -> Float {
		if cushion >= target { return 1 }
		if current < 1 || cushion < target - 1 { return slowRate }
		return 1
	}

	/// The cushion to build: the saved buffer, at least [liveCushionSeconds], at most the
	/// maximum, plus one second per stall (desktop: base_buffer_seconds + 1 per stall).
	public static func target(base: Double, max: Double, stalls: Int) -> Double {
		min(max, Swift.max(liveCushionSeconds, base) + Double(stalls))
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
		if last != 0 && now - last >= Reconnect.resetMs { attempts = 0 }
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
