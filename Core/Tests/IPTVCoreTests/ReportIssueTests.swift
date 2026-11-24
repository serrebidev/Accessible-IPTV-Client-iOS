import XCTest
@testable import IPTVCore

final class ReportIssueTests: XCTestCase {
	func testIssueLinkCarriesTitleBodyAndVersion() {
		let url = ReportIssue.url(title: "Photo & video", details: "Line 1\nПривет", appLine: "Accessible IPTV Client 1.0 on iOS 27").absoluteString
		XCTAssertTrue(url.hasPrefix("https://github.com/serrebidev/Accessible-IPTV-Client-iOS/issues/new?title=Photo%20%26%20video&body=Line%201%0A%D0%9F"), url)
		XCTAssertTrue(url.hasSuffix("%0A---%0AAccessible%20IPTV%20Client%201.0%20on%20iOS%2027"), url)
		XCTAssertFalse(url.contains(" ") || url.contains("#"), url)
	}
}
