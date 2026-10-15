#if canImport(SQLite3)
import XCTest
@testable import IPTVCore
#if canImport(Compression)
import Compression
#endif

/// The SQLite guide: import, matching, now/next, search, and keeping the old guide when an
/// import fails. Port of the Android GuideTest.
final class GuideTests: XCTestCase {
	var dir: URL!
	var epg: Epg!
	let now = nowMs() / 60_000 * 60_000
	let h: Int64 = 3_600_000

	override func setUpWithError() throws {
		dir = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		epg = try Epg(path: dir.appendingPathComponent("epg.db").path)
	}

	override func tearDown() {
		epg = nil
		try? FileManager.default.removeItem(at: dir)
	}

	func t(_ ms: Int64) -> String {
		let w = Catchup.wall(ms, TimeZone(identifier: "UTC")!)
		return String(format: "%04d%02d%02d%02d%02d%02d +0000", w.year, w.month, w.day, w.hour, w.minute, w.second)
	}

	struct P { let ch: String; let start: Int64; let stop: Int64; let title: String; var desc = "" }

	func xml(_ channels: [(String, String)], _ progs: [P]) -> String {
		var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
		for (id, name) in channels { s += "<channel id=\"\(id)\"><display-name>\(name)</display-name><icon src=\"x\"/></channel>\n" }
		for p in progs { s += "<programme start=\"\(t(p.start))\" stop=\"\(t(p.stop))\" channel=\"\(p.ch)\"><title lang=\"en\">\(p.title)</title><desc>\(p.desc)</desc><credits><actor>A</actor></credits></programme>\n" }
		return s + "</tv>\n"
	}

	func ch(_ name: String, _ tvg: String = "") -> Channel { Channel(sourceId: "s", itemId: name, name: name, group: "G", url: "http://h/\(name).ts", tvgId: tvg) }

	lazy var bbc = ch("BBC One", "bbc1.uk")
	let standard = [("bbc1.uk", "BBC One")]
	lazy var ab = [P(ch: "bbc1.uk", start: now - h, stop: now + h, title: "A"), P(ch: "bbc1.uk", start: now + h, stop: now + 2 * h, title: "B")]

	@discardableResult
	func load(_ docs: [String], channels: [Channel]? = nil) async throws -> Int {
		try await epg.importGuide(docs.map { d in { try sniffGzip(DataSource(Data(d.utf8), chunk: 4096)) } }, channels: channels ?? [bbc], fromMs: now - 24 * h, toMs: now + 48 * h)
	}

	func testNowAndNext() async throws {
		let n = try await load([xml(standard, ab)])
		XCTAssertEqual(n, 2)
		let nn = epg.nowNext(bbc, now: now)
		XCTAssertEqual(nn.now?.title, "A")
		XCTAssertEqual(nn.next?.title, "B")
	}

	/// The remembered now/next answer belongs to the guide it came from: an import replaces it.
	func testNowNextFollowsANewGuide() async throws {
		try await load([xml(standard, ab)])
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
		try await load([xml(standard, [P(ch: "bbc1.uk", start: now - h, stop: now + h, title: "New")])])
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "New")
		XCTAssertNil(epg.nowNext(bbc, now: now).next)
	}

	func testAGapHasNoNowOnlyANext() async throws {
		try await load([xml(standard, [P(ch: "bbc1.uk", start: now + h, stop: now + 2 * h, title: "Later")])])
		let nn = epg.nowNext(bbc, now: now)
		XCTAssertNil(nn.now, "a programme that has not started is not on now")
		XCTAssertEqual(nn.next?.title, "Later")
	}

	func testMatchesByNameWhenThereIsNoTvgId() async throws {
		let noId = ch("UK: BBC One")
		try await load([xml([("x1", "BBC One HD")], [P(ch: "x1", start: now - h, stop: now + h, title: "A")])], channels: [noId])
		XCTAssertEqual(epg.nowNext(noId, now: now).now?.title, "A")
	}

	func testTvgIdIgnoresCase() async throws {
		try await load([xml([("BBC1.UK", "Whatever")], [P(ch: "BBC1.UK", start: now - h, stop: now + h, title: "A")])])
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
	}

	func testUnmatchedChannelsAndOldProgrammesAreNotStored() async throws {
		let n = try await load([xml(standard + [("other", "Other")], ab + [P(ch: "other", start: now, stop: now + h, title: "X"), P(ch: "bbc1.uk", start: now - 30 * h, stop: now - 29 * h, title: "Old")])])
		XCTAssertEqual(n, 2)
	}

	func testAChannelInTwoGuidesIsNotDoubled() async throws {
		let n = try await load([xml(standard, ab), xml(standard, ab)])
		XCTAssertEqual(n, 2)
		XCTAssertEqual(epg.nowNext(bbc, now: now).next?.title, "B")
	}

	#if canImport(Compression)
	/// Raw DEFLATE from Compression wrapped in a gzip header; the trailer is not checked.
	func testGzipGuide() async throws {
		let raw = Array(xml(standard, ab).utf8)
		var out = [UInt8](repeating: 0, count: raw.count + 1024)
		let n = compression_encode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_ZLIB)
		XCTAssertGreaterThan(n, 0)
		let gz = Data([0x1f, 0x8b, 8, 8, 0, 0, 0, 0, 0, 3] + Array("g.xml".utf8) + [0] + out[0..<n] + [0, 0, 0, 0, 0, 0, 0, 0])
		let count = try await epg.importGuide([{ try sniffGzip(DataSource(gz, chunk: 100)) }], channels: [bbc], fromMs: now - 24 * h, toMs: now + 48 * h)
		XCTAssertEqual(count, 2)
		// Small bodies unwrap the same way.
		XCTAssertEqual(try gunzipIfNeeded(gz), Data(raw))
		// A cut-off gzip is an error, not half a guide.
		let cut = gz.prefix(gz.count / 2)
		do {
			_ = try await epg.importGuide([{ try sniffGzip(DataSource(cut)) }], channels: [bbc], fromMs: now - 24 * h, toMs: now + 48 * h)
			XCTFail("cut-off gzip imported")
		} catch {}
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
	}
	#endif

	func testAFailedImportKeepsTheOldGuide() async throws {
		try await load([xml(standard, ab)])
		do {
			_ = try await epg.importGuide([{ DataSource(Data(self.xml(self.standard, self.ab).utf8)) }, { throw NetError.status(404) }], channels: [bbc], fromMs: now - 24 * h, toMs: now + 48 * h)
			XCTFail("missing guide imported")
		} catch {}
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
	}

	func testACutOffGuideKeepsTheOldGuide() async throws {
		try await load([xml(standard, ab)])
		let full = xml(standard, ab)
		let cut = String(full[..<full.range(of: "<credits>")!.lowerBound])
		do { try await load([cut]); XCTFail("cut-off guide imported") } catch {}
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
	}

	func testReimportReplacesInsteadOfAdding() async throws {
		try await load([xml(standard, ab)])
		try await load([xml(standard, ab)])
		XCTAssertEqual(epg.schedule(bbc, from: now - 24 * h, to: now + 24 * h).count, 2)
	}

	func testSearchTreatsWildcardsAsText() async throws {
		try await load([xml(standard, [P(ch: "bbc1.uk", start: now - h, stop: now + h, title: "100% Hits"), P(ch: "bbc1.uk", start: now + h, stop: now + 2 * h, title: "100 Greatest", desc: "a_b")])])
		XCTAssertEqual(epg.search("100%", [bbc], now: now).map(\.0.title), ["100% Hits"])
		XCTAssertEqual(epg.search("a_b", [bbc], now: now).map(\.0.title), ["100 Greatest"])
		XCTAssertEqual(epg.search("x_y", [bbc], now: now).map(\.0.title), [])
	}

	func testSearchSkipsWhatHasEnded() async throws {
		try await load([xml(standard, [P(ch: "bbc1.uk", start: now - 3 * h, stop: now - 2 * h, title: "News"), P(ch: "bbc1.uk", start: now + h, stop: now + 2 * h, title: "News")])])
		XCTAssertEqual(epg.search("news", [bbc], now: now).count, 1)
	}

	func testOnNowListsEveryChannelSortedByTitle() async throws {
		let itv = ch("ITV", "itv.uk")
		try await load([xml(standard + [("itv.uk", "ITV")], [P(ch: "bbc1.uk", start: now - h, stop: now + h, title: "zebra"), P(ch: "itv.uk", start: now - h, stop: now + h, title: "Apple")])], channels: [bbc, itv])
		XCTAssertEqual(epg.onNow([bbc, itv], now: now).map { "\($0.0.title)/\($0.1.name)" }, ["Apple/ITV", "zebra/BBC One"])
	}

	func testXmlEntitiesAreDecoded() async throws {
		try await load([xml(standard, [P(ch: "bbc1.uk", start: now - h, stop: now + h, title: "Tom &amp; Jerry")])])
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "Tom & Jerry")
	}

	func testNoGuideMeansEmptyNotACrash() {
		XCTAssertTrue(epg.nowNext(ch("Nothing"), now: now).isEmpty)
		XCTAssertEqual(epg.schedule(ch("Nothing"), from: 0, to: Int64.max), [])
	}

	/// Channel rows read now/next on the main thread; a slow guide download must not block them.
	func testReadsDoNotWaitForAnImportInProgress() async throws {
		try await load([xml(standard, ab)])
		let gate = DispatchSemaphore(value: 0)
		let sent = DispatchSemaphore(value: 0)
		final class Slow: ByteSource {
			var parts: [Data]
			let gate: DispatchSemaphore, sent: DispatchSemaphore
			init(_ parts: [Data], _ gate: DispatchSemaphore, _ sent: DispatchSemaphore) { self.parts = parts; self.gate = gate; self.sent = sent }
			func next() throws -> Data? {
				if parts.count == 1 { sent.signal(); _ = gate.wait(timeout: .now() + 30) }
				return parts.isEmpty ? nil : parts.removeFirst()
			}
		}
		let full = xml(standard, ab)
		let cut = full.range(of: "</tv>")!.lowerBound
		let slow = Slow([Data(full[..<cut].utf8), Data(full[cut...].utf8)], gate, sent)
		let epg = self.epg!, bbc = self.bbc, now = self.now, h = self.h
		let importer = Task.detached { try await epg.importGuide([{ slow }], channels: [bbc], fromMs: now - 24 * h, toMs: now + 48 * h) }
		XCTAssertEqual(sent.wait(timeout: .now() + 10), .success)
		XCTAssertEqual(epg.nowNext(bbc, now: now).now?.title, "A")
		gate.signal()
		_ = try await importer.value
	}
}
#endif
