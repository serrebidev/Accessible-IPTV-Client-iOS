import Foundation

/// Settings, About, Report an issue on GitHub: GitHub's new-issue page with the title and
/// description the user typed filled in and the version line added. GitHub needs the user's own
/// account, so the last step, Create, is theirs in the browser.
public enum ReportIssue {
	public static func url(title: String, details: String, appLine: String) -> URL {
		let body = "\(details.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\(appLine)"
		let page = "https://github.com/serrebidev/Accessible-IPTV-Client-iOS/issues/new"
		return URL(string: "\(page)?title=\(encode(title.trimmingCharacters(in: .whitespacesAndNewlines)))&body=\(encode(body))")!
	}

	/// Percent-encode a query value: everything but unreserved ASCII.
	private static func encode(_ text: String) -> String {
		let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
		return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
	}
}
