import XCTest
@testable import IPTVCore

/// The reconnect budget both players share with the desktop: backoff of 0.4, 2, 4, 8,
/// 8, 8 s, then give up, with the count starting again after two quiet minutes.
final class ReconnectTests: XCTestCase {
	private var now: Int64 = 0
	private func reconnect() -> Reconnect { Reconnect(clock: { [unowned self] in self.now }) }

	func testBackoffThenGiveUp() {
		let r = reconnect()
		XCTAssertEqual((1...6).map { _ in r.next() }, [400, 2_000, 4_000, 8_000, 8_000, 8_000])
		XCTAssertNil(r.next())
		XCTAssertNil(r.next(), "Given up stays given up until a fresh start or a quiet window")
	}

	func testQuietWindowStartsTheBudgetAgain() {
		let r = reconnect()
		for _ in 1...6 { _ = r.next() }
		XCTAssertNil(r.next())
		now += Reconnect.resetMs - 1
		XCTAssertNil(r.next(), "Just under two quiet minutes is not a fresh budget")
		now += 1
		XCTAssertEqual(r.next(), 400)
	}

	func testSuccessfulPlayDoesNotSpendTheBudgetEarly() {
		let r = reconnect()
		XCTAssertEqual(r.next(), 400)
		// An hour of good playback, then one drop: a fresh budget, from the top.
		now += 3_600_000
		XCTAssertEqual(r.next(), 400)
	}

	func testResetRestoresTheBudgetAtOnce() {
		let r = reconnect()
		for _ in 1...6 { _ = r.next() }
		XCTAssertNil(r.next())
		r.reset()
		XCTAssertEqual(r.next(), 400)
	}
}
