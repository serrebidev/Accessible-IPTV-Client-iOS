import XCTest
@testable import IPTVCore

/// Rough speed checks for the parsers that run on whole guides and VOD lists. They print
/// MB/s; the bounds only catch something pathological (a hang or a 10x regression).
final class PerfTests: XCTestCase {
	/// A national-guide shape: 2,000 channels, 60 programmes each, 1 in 100 channels matched.
	static let guide: Data = {
		var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"x\">\n"
		for c in 0..<2000 { s += "  <channel id=\"ch\(c).tv\"><display-name lang=\"en\">Channel \(c) HD</display-name><icon src=\"http://i/\(c).png\"/></channel>\n" }
		for c in 0..<2000 {
			for p in 0..<60 {
				s += "  <programme start=\"20261014\(String(format: "%02d", p % 24))0000 +0000\" stop=\"20261014\(String(format: "%02d", p % 24))3000 +0000\" channel=\"ch\(c).tv\">"
				s += "<title lang=\"en\">Programme \(p) &amp; friends</title><desc lang=\"en\">A fairly long description of programme \(p) on channel \(c), the sort of text guides carry for every show &amp; episode.</desc>"
				s += "<category lang=\"en\">News</category><episode-num system=\"xmltv_ns\">1.\(p).</episode-num></programme>\n"
			}
		}
		return Data((s + "</tv>\n").utf8)
	}()

	func testXmlPullThroughput() throws {
		let data = PerfTests.guide
		let keep: Set<String> = Set((0..<2000).filter { $0 % 100 == 0 }.map { "ch\($0).tv" })
		let t0 = Date()
		let p = XmlPull(DataSource(data))
		var titles = 0
		while try p.next() != .eof {
			guard p.event == .start, p.name == "programme" else { continue }
			guard keep.contains(p.attrs["channel"] ?? "") else { try p.skipElement(); continue }
			while true {
				let e = try p.next()
				if e == .end && p.name == "programme" { break }
				if e == .start && p.name == "title" { _ = try p.nextText(); titles += 1 }
			}
		}
		let secs = Date().timeIntervalSince(t0)
		print("XmlPull: \(data.count / 1_000_000) MB in \(String(format: "%.2f", secs)) s = \(String(format: "%.0f", Double(data.count) / 1e6 / secs)) MB/s")
		XCTAssertEqual(titles, 20 * 60)
		XCTAssertLessThan(secs, 60)
	}

	func testJsonStreamThroughput() throws {
		var s = "["
		for i in 0..<100_000 { s += (i > 0 ? "," : "") + #"{"num":\#(i),"name":"Movie \#(i) (2020)","stream_type":"movie","stream_id":\#(i),"stream_icon":"http:\/\/i\/\#(i).jpg","rating":"7.1","category_id":"12","container_extension":"mkv","custom_sid":null,"direct_source":""}"# }
		let data = Data((s + "]").utf8)
		let t0 = Date()
		var n = 0
		try JsonStream(DataSource(data)).forEachObject { _ in n += 1 }
		let secs = Date().timeIntervalSince(t0)
		print("JsonStream: \(data.count / 1_000_000) MB in \(String(format: "%.2f", secs)) s = \(String(format: "%.0f", Double(data.count) / 1e6 / secs)) MB/s")
		XCTAssertEqual(n, 100_000)
		XCTAssertLessThan(secs, 60)
	}

	/// What a fresh launch does per channel (guide fingerprint) and what each search keystroke does.
	func testNameKeyAndSearchSpeed() {
		let names = (0..<50_000).map { "UK: Channel Number \($0) HD | Sports & News" }
		var t0 = Date()
		var total = 0
		for n in names { total += Xmltv.nameKey(n).count }
		print("nameKey: 50k names in \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
		let list = names.enumerated().map { Channel(sourceId: "s", itemId: String($0.offset), name: $0.element, group: "G", url: "u") }
		let lower = list.map { Lists.lowerName($0.name) }
		t0 = Date()
		let hits = Lists.ranked(list, lower, "number 12")
		print("ranked (names kept by the Library): 50k in \(String(format: "%.3f", Date().timeIntervalSince(t0))) s, \(hits.count) hits")
		t0 = Date()
		let slow = Lists.searchRanked(list, "number 12")
		print("searchRanked (lowercases every name first): 50k in \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
		XCTAssertGreaterThan(total, 0)
		XCTAssertEqual(hits.count, 1111)
		// The app searches with the names the Library kept: same names, same order, same result.
		XCTAssertEqual(hits.map(\.key), slow.map(\.key))
	}
}
