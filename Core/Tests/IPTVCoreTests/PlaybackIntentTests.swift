import XCTest
@testable import IPTVCore

final class PlaybackIntentTests: XCTestCase {
	func testInterruptionResumesOnlyPreviouslyWantedPlayback() {
		var intent = PlaybackIntent()
		XCTAssertTrue(intent.canPlay)
		intent.beginInterruption()
		XCTAssertFalse(intent.canPlay)
		XCTAssertTrue(intent.endInterruption(shouldResume: true))
		intent.pause()
		intent.beginInterruption()
		XCTAssertFalse(intent.endInterruption(shouldResume: true))
		XCTAssertFalse(intent.canPlay)
	}

	func testPauseDuringInterruptionCancelsAutomaticResume() {
		var intent = PlaybackIntent()
		intent.beginInterruption()
		intent.pause()
		XCTAssertFalse(intent.endInterruption(shouldResume: true))
		intent.play()
		XCTAssertTrue(intent.canPlay)
	}

	func testSystemDenialRequiresExplicitPlay() {
		var intent = PlaybackIntent()
		intent.beginInterruption()
		XCTAssertFalse(intent.endInterruption(shouldResume: false))
		XCTAssertFalse(intent.canPlay)
		intent.play()
		XCTAssertTrue(intent.canPlay)
	}

	func testUnpairedEndDoesNotStartPlayback() {
		var intent = PlaybackIntent()
		XCTAssertFalse(intent.endInterruption(shouldResume: true))
	}
}
