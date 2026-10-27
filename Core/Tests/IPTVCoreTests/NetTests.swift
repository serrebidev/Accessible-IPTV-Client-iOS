import XCTest
@testable import IPTVCore

/// Connection warm-up hosts: the Android port's rules — distinct scheme/host/port
/// roots, first seen first, capped, header suffixes and bad addresses skipped.
final class NetTests: XCTestCase {
	func testWarmHostsDedupesCapsAndSkipsBadUrls() {
		let hosts = Net.warmHosts([
			"https://tv.example.com/proxy/ts/stream/aaa",
			"https://tv.example.com/proxy/ts/stream/bbb",
			"http://other.example.net:8080/live/1.ts",
			"not a url",
			"https://third.example.org/x",
		]).map { $0.absoluteString }
		XCTAssertEqual(["https://tv.example.com/", "http://other.example.net:8080/"], hosts)
	}

	func testWarmHostsStripsHeaderSuffixAndDefaultsPorts() {
		let hosts = Net.warmHosts([
			"http://h.example/live/1.ts|User-Agent=VLC",
			"http://h.example/live/2.ts",
			"https://h.example/live/3.ts",
		]).map { $0.absoluteString }
		// Same host on http and https are two hosts worth warming; the pipe tail is ignored.
		XCTAssertEqual(["http://h.example/", "https://h.example/"], hosts)
		XCTAssertTrue(Net.warmHosts([]).isEmpty())
	}
}
