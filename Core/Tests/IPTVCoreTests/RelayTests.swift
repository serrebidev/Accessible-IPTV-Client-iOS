import XCTest
@testable import IPTVCore

final class RelayTests: XCTestCase {
	private let digest = String(repeating: "a", count: 64)

	private func entry(_ seq: Int) -> RelayEntry { RelayEntry(seq: seq, id: UUID(), sha256: digest, size: Relay.packet * 10) }

	func testCutKeepsWholePacketsWithinOneChunk() {
		XCTAssertEqual(Relay.cut(187), 0)
		XCTAssertEqual(Relay.cut(188 * 3 + 50), 188 * 3)
		XCTAssertEqual(Relay.cut(Relay.maxChunk * 2) % Relay.packet, 0)
		XCTAssertLessThanOrEqual(Relay.cut(Relay.maxChunk * 2), Relay.maxChunk)
	}

	func testSyncOffsetFindsFirstPacket() {
		var bytes = [UInt8](repeating: 0, count: 5)
		for _ in 0..<3 { bytes += [0x47] + [UInt8](repeating: 1, count: 187) }
		XCTAssertEqual(Relay.syncOffset(bytes), 5)
		XCTAssertNil(Relay.syncOffset(Array(bytes.prefix(300))))
		XCTAssertNil(Relay.syncOffset([UInt8](repeating: 0, count: 1000)))
	}

	func testWindowRejectsUnorderedOrOversizedEntries() {
		let g = UUID()
		XCTAssertTrue(RelayWindow(generation: g, paused: false, entries: [entry(1), entry(2)]).isValid)
		XCTAssertFalse(RelayWindow(generation: g, paused: false, entries: [entry(2), entry(1)]).isValid)
		let odd = RelayEntry(seq: 1, id: UUID(), sha256: digest, size: 100)
		XCTAssertFalse(RelayWindow(generation: g, paused: false, entries: [odd]).isValid)
		let badHash = RelayEntry(seq: 1, id: UUID(), sha256: "zz", size: Relay.packet)
		XCTAssertFalse(RelayWindow(generation: g, paused: false, entries: [badHash]).isValid)
		XCTAssertFalse(RelayWindow(generation: g, paused: false, entries: (0..<40).map(entry)).isValid)
	}

	func testReceiverJoinsNearLiveEdgeThenFollowsInOrder() {
		var r = RelayReceiver()
		let g = UUID()
		let w = RelayWindow(generation: g, paused: false, entries: (3...8).map(entry))
		let first = r.next(in: w)
		XCTAssertTrue(first.reset)
		XCTAssertEqual(first.entry?.seq, 8 - Relay.lead + 1)
		r.advance(past: 7)
		let second = r.next(in: w)
		XCTAssertFalse(second.reset)
		XCTAssertEqual(second.entry?.seq, 8)
		r.advance(past: 8)
		XCTAssertNil(r.next(in: w).entry)
	}

	func testReceiverSkipsRemovedChunksAndRestartsOnNewGeneration() {
		var r = RelayReceiver()
		let g = UUID()
		_ = r.next(in: RelayWindow(generation: g, paused: false, entries: [entry(1), entry(2)]))
		r.advance(past: 1)
		// Fell behind: chunks 2...9 were removed from the journal.
		XCTAssertEqual(r.next(in: RelayWindow(generation: g, paused: false, entries: (10...12).map(entry))).entry?.seq, 10)
		let restarted = r.next(in: RelayWindow(generation: UUID(), paused: false, entries: [entry(0)]))
		XCTAssertTrue(restarted.reset)
		XCTAssertEqual(restarted.entry?.seq, 0)
	}

	func testBufferReadsWaitAndJumpPastTrimmedBytes() {
		let b = RelayBuffer(capacity: Relay.packet * 4)
		XCTAssertEqual(b.read(from: 0, max: 100, timeout: 0.01)?.bytes.count, 0)
		b.append([UInt8](repeating: 1, count: Relay.packet * 6))
		// 6 packets > capacity + capacity/4: trimmed to 4 packets.
		let read = b.read(from: 0, max: Relay.packet * 10, timeout: 0)
		XCTAssertEqual(read?.bytes.count, Relay.packet * 4)
		XCTAssertEqual(read?.next, Relay.packet * 6)
		XCTAssertEqual(b.start(back: Relay.packet + 5), Relay.packet * 5)
		b.reset()
		XCTAssertEqual(b.read(from: 0, max: 10, timeout: 0)?.next, Relay.packet * 6)
		b.close()
		XCTAssertNil(b.read(from: Relay.packet * 6, max: 10, timeout: 1))
	}

	func testBufferWakesWaitingReader() {
		let b = RelayBuffer()
		let done = expectation(description: "read")
		DispatchQueue.global().async {
			XCTAssertEqual(b.read(from: 0, max: 10, timeout: 5)?.bytes, [7, 7])
			done.fulfill()
		}
		Thread.sleep(forTimeInterval: 0.05)
		b.append([7, 7])
		wait(for: [done], timeout: 5)
	}
}
