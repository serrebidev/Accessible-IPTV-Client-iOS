import XCTest
@testable import IPTVCore

/// The playback-health rules both players share with the desktop: a reopen waits with
/// the whole cushion, stalls restart playback with a bigger one, and a channel that
/// never plays is given up on.
final class StallTrackerTests: XCTestCase {
	private var now = 0.0
	private func tracker() -> StallTracker { StallTracker(now: { [unowned self] in self.now }) }

	func testFirstOpenIsQuickAndReopenWaitsWithTheWholeCushion() {
		XCTAssertEqual(Cushion.openSeconds(base: 25, max: 30, stalls: 0, reopened: false), 0.5)
		XCTAssertEqual(Cushion.openSeconds(base: 25, max: 30, stalls: 0, reopened: true), 25)
		XCTAssertEqual(Cushion.openSeconds(base: 25, max: 30, stalls: 3, reopened: true), 28)
		XCTAssertEqual(Cushion.openSeconds(base: 25, max: 30, stalls: 9, reopened: true), 30)
		// A saved cushion under the quick start is the whole wait either way.
		XCTAssertEqual(Cushion.openSeconds(base: 0.25, max: 30, stalls: 0, reopened: false), 0.25)
	}

	func testNoMediaRestartsAt25SecondsAndNeverPlayedGivesUpAt30() {
		var t = tracker()
		now = 24
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 25
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .restart)
		t.prepared()
		now = 29
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 30
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .giveUp)
		// Given up is final for this channel; a fresh request resets the tracker.
		now = 90
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		t.reset()
		now = 91
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
	}

	func testPlayingBeforeTheDeadlineDisarmsIt() {
		var t = tracker()
		now = 20
		t.playing()
		now = 45
		XCTAssertEqual(t.tick(buffering: false, frozen: 0), .none)
	}

	func testProlongedBufferingRestartsWithABiggerCushion() {
		var t = tracker()
		now = 1
		t.playing()
		now = 5
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 14
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 15
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .restartGrown)
	}

	func testShortBlipsDoNotCountButFourLongOnesAreChoppy() {
		var t = tracker()
		now = 1
		t.playing()
		// Four 1 s blips: under the 1.25 s event floor, nothing happens.
		for start in stride(from: 2.0, through: 14.0, by: 4.0) {
			now = start
			_ = t.tick(buffering: true, frozen: 0)
			now = start + 1
			XCTAssertEqual(t.tick(buffering: false, frozen: 0), .none)
		}
		// Four 2 s episodes inside a minute: the fourth asks for a bigger cushion.
		var verdict = StallTracker.Verdict.none
		for start in stride(from: 20.0, through: 32.0, by: 4.0) {
			now = start
			_ = t.tick(buffering: true, frozen: 0)
			now = start + 2
			verdict = t.tick(buffering: false, frozen: 0)
		}
		XCTAssertEqual(verdict, .restartGrown)
		// The 20 s cooldown holds the next choppy verdict back.
		for start in stride(from: 36.0, through: 48.0, by: 4.0) {
			now = start
			_ = t.tick(buffering: true, frozen: 0)
			now = start + 2
			verdict = t.tick(buffering: false, frozen: 0)
		}
		XCTAssertEqual(verdict, .none)
	}

	func testReopenGetsFreshStartupGraceBeforeFrozenClockCanRestart() {
		var t = tracker()
		t.playing()
		now = 100
		t.prepared()
		t.playing()
		now = 110
		XCTAssertEqual(t.tick(buffering: false, frozen: 10), .none)
		now = 112
		XCTAssertEqual(t.tick(buffering: false, frozen: 12), .restartGrown)
	}

	func testReopenDoesNotCountCacheFillAsProlongedBuffering() {
		var t = tracker()
		t.playing()
		now = 100
		t.prepared()
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 110
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 112
		t.playing()
		now = 150
		XCTAssertEqual(t.tick(buffering: false, frozen: 0), .none)
	}

	func testReopenWaitsForSavedCacheAndThenDetectsAFrozenClock() {
		var t = tracker()
		t.playing()
		now = 100
		t.prepared(caching: 25)
		t.playing()
		now = 125
		XCTAssertEqual(t.tick(buffering: true, frozen: 25), .none)
		now = 137
		XCTAssertEqual(t.tick(buffering: false, frozen: 37), .restartGrown)
	}

	func testReopenWithoutMediaStillRestartsWithoutGrowingTheBuffer() {
		var t = tracker()
		t.playing()
		now = 100
		t.prepared(caching: 25)
		now = 125
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .none)
		now = 137
		XCTAssertEqual(t.tick(buffering: true, frozen: 0), .restart)
	}

	func testFrozenProgressRestartsWithABiggerCushion() {
		var t = tracker()
		now = 1
		t.playing()
		// Frozen solid, but still inside the 12 s startup grace: no verdict.
		now = 11
		XCTAssertEqual(t.tick(buffering: false, frozen: 10), .none)
		now = 15
		XCTAssertEqual(t.tick(buffering: false, frozen: 9), .none)
		now = 16
		XCTAssertEqual(t.tick(buffering: false, frozen: 10), .restartGrown)
	}
}
