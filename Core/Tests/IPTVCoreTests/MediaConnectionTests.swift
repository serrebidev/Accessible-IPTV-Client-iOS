import XCTest
@testable import IPTVCore

final class MediaConnectionTests: XCTestCase {
	@MainActor
	func testOnlyOneOwnerUntilTeardownFinishes() async {
		let connection = MediaConnection()
		let playback = UUID(), recording = UUID()
		let first = await connection.acquire(playback)
		XCTAssertTrue(first)
		let duplicate = await connection.acquire(playback)
		XCTAssertTrue(duplicate)
		let blocked = await connection.acquire(recording)
		XCTAssertFalse(blocked)
		connection.release(recording)
		let stillBlocked = await connection.acquire(recording)
		XCTAssertFalse(stillBlocked, "An unrelated owner must not release playback")
		var finish: CheckedContinuation<Void, Never>?
		let stopping = expectation(description: "Transport teardown started")
		connection.release(playback) {
			await withCheckedContinuation { finish = $0; stopping.fulfill() }
		}
		await fulfillment(of: [stopping], timeout: 2)
		guard let finish else { return }
		var acquired = false
		let next = Task { @MainActor in acquired = await connection.acquire(recording) }
		await Task.yield()
		XCTAssertFalse(acquired, "The next stream must wait for the old connection to close")
		finish.resume()
		await next.value
		XCTAssertTrue(acquired)
		connection.release(recording)
	}

	@MainActor
	func testCancelledWaiterCannotClaimConnection() async {
		let connection = MediaConnection()
		let owner = UUID()
		let acquired = await connection.acquire(owner)
		XCTAssertTrue(acquired)
		connection.release(owner)
		let cancelled = Task { @MainActor in await connection.acquire(UUID()) }
		cancelled.cancel()
		let result = await cancelled.value
		XCTAssertFalse(result)
		let available = await connection.acquire(UUID())
		XCTAssertTrue(available)
	}
}
