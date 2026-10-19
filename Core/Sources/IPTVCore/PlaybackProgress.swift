import Foundation

/// Decoder/output counters supersede unreliable live presentation clocks, as on desktop.
public struct PlaybackProgress {
	public struct Counters: Equatable {
		public let decoded: UInt64
		public let output: UInt64
		public init(decoded: UInt64, output: UInt64) { self.decoded = decoded; self.output = output }
	}

	private struct Track {
		var previous: Counters?
		var changes = 0
		var changedAt = 0.0

		mutating func sample(_ counters: Counters?, at time: Double) -> Double? {
			guard let counters else { self = Track(); return nil }
			if let previous, counters != previous {
				changes += 1
				changedAt = time
			}
			previous = counters
			// Two changes avoid arming a radio station's single artwork frame.
			return changes >= 2 ? time - changedAt : nil
		}
	}

	private let now: () -> Double
	private var audio = Track()
	private var video = Track()
	private var lastPosition: Double?
	private var positionChangedAt = 0.0
	private var clockAdvanced = false

	public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
	public mutating func reset() { self = PlaybackProgress(now: now) }

	/// Omit video counters when video is disabled in the background. Unavailable clocks
	/// and clocks that never advanced provide no evidence of a playback stall.
	public mutating func sample(position: Double?, audio: Counters? = nil, video: Counters? = nil) -> Double {
		let time = now()
		let audioFrozen = self.audio.sample(audio, at: time)
		let videoFrozen = self.video.sample(video, at: time)
		var clockFrozen = 0.0
		if let position, position.isFinite, position >= 0 {
			if let previous = lastPosition, position != previous {
				clockAdvanced = true
				positionChangedAt = time
			} else if lastPosition == nil { positionChangedAt = time }
			lastPosition = position
			if clockAdvanced { clockFrozen = time - positionChangedAt }
		} else {
			lastPosition = nil
			clockAdvanced = false
		}
		if audioFrozen != nil || videoFrozen != nil {
			// Losing counters must not reuse time accumulated by an unreliable clock.
			positionChangedAt = time
			return max(audioFrozen ?? 0, videoFrozen ?? 0)
		}
		return clockFrozen
	}
}
