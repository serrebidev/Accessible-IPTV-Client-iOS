import XCTest
@testable import IPTVCore

final class PlaybackLogTests: XCTestCase {
	func testStampsInUtcAndKeepsOnlyTheNewestLines() {
		let log = PlaybackLog(clock: { Date(timeIntervalSince1970: 1_793_054_206.5) })
		for i in 0..<(PlaybackLog.limit + 5) { log.add("line \(i)") }
		let lines = log.text.split(separator: "\n")
		XCTAssertEqual(lines.count, PlaybackLog.limit)
		XCTAssertEqual(lines.first, "2026-10-26T22:36:46.500Z line 5")
		XCTAssertEqual(lines.last, "2026-10-26T22:36:46.500Z line \(PlaybackLog.limit + 4)")
	}

	func testStatsLineReportsChangesAndSurvivesACounterRestart() {
		var old = PlaybackStats()
		old.readBytes = 1_000_000
		old.discontinuities = 2
		old.lostPictures = 10
		var new = old
		new.readBytes = 8_250_000
		new.inputKbps = 5800
		new.discontinuities = 3
		new.lostPictures = 4 // reopened: libVLC counted from zero again
		let line = new.line(since: old, seconds: 10)
		XCTAssertTrue(line.hasPrefix("stats 10 s: received 5.80 Mbps, input 5800 kbps"), line)
		XCTAssertTrue(line.contains("discontinuities +1"), line)
		XCTAssertTrue(line.contains("lost +4, audio"), line)
	}
}
