import XCTest
@testable import IPTVCore

final class PlaybackProgressTests: XCTestCase {
	private var now = 0.0
	private func tracker() -> PlaybackProgress { PlaybackProgress(now: { [unowned self] in self.now }) }
	private func counters(_ n: UInt64) -> PlaybackProgress.Counters { .init(decoded: n, output: n) }

	func testAdvancingAudioOverridesAnUnchangingLiveClock() {
		var t = tracker()
		for n in 0...30 {
			now = Double(n)
			XCTAssertEqual(t.sample(position: 0, audio: counters(UInt64(n))), 0)
		}
	}

	func testFrozenAudioIsDetectedEvenWhenTheClockAdvances() {
		var t = tracker()
		for n in 0...2 {
			now = Double(n)
			_ = t.sample(position: now, audio: counters(UInt64(n)))
		}
		now = 12
		XCTAssertEqual(t.sample(position: 12, audio: counters(2)), 10)
	}

	func testBackgroundVideoDoesNotInvalidateAdvancingAudio() {
		var t = tracker()
		for n in 0...2 {
			now = Double(n)
			_ = t.sample(position: now, audio: counters(UInt64(n)), video: counters(UInt64(n)))
		}
		now = 20
		XCTAssertEqual(t.sample(position: 20, audio: counters(20), video: nil), 0)
	}

	func testFrozenVideoIsDetectedWhileAudioContinues() {
		var t = tracker()
		for n in 0...2 {
			now = Double(n)
			_ = t.sample(position: now, audio: counters(UInt64(n)), video: counters(UInt64(n)))
		}
		now = 12
		XCTAssertEqual(t.sample(position: 12, audio: counters(12), video: counters(2)), 10)
	}

	func testUnavailableOrNeverAdvancingClocksCannotDeclareAStall() {
		for position: Double? in [nil, -1, .nan, .infinity, 0] {
			var t = tracker()
			_ = t.sample(position: position)
			now += 20
			XCTAssertEqual(t.sample(position: position), 0)
		}
	}

	func testMovingClockIsFallbackWhenCountersAreUnavailable() {
		var t = tracker()
		_ = t.sample(position: 0)
		now = 1
		_ = t.sample(position: 1)
		now = 11
		XCTAssertEqual(t.sample(position: 1), 10)
		t.reset()
		now = 50
		XCTAssertEqual(t.sample(position: 1), 0)
	}

	func testLosingCountersDoesNotReuseAnOldFrozenClock() {
		var t = tracker()
		for n in 0...30 {
			now = Double(n)
			_ = t.sample(position: min(now, 5), audio: counters(UInt64(n)))
		}
		now = 31
		XCTAssertLessThan(t.sample(position: 5), 10)
		now = 40
		XCTAssertEqual(t.sample(position: 5), 10)
	}

	func testCounterResetAndAlbumArtworkDoNotLookLikeFrozenVideo() {
		var t = tracker()
		for n in 0...20 {
			now = Double(n)
			XCTAssertEqual(t.sample(position: 0, audio: counters(UInt64(n % 5)), video: counters(1)), 0)
		}
	}
}
