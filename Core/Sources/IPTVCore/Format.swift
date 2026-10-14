import Foundation

public enum Format {
	private static func formatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
		let f = DateFormatter()
		f.dateStyle = date
		f.timeStyle = time
		return f
	}
	private static let timeF = formatter(.none, .short)
	private static let dateF = formatter(.medium, .none)
	private static let dateTimeF = formatter(.medium, .short)

	private static func d(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
	public static func time(_ ms: Int64) -> String { timeF.string(from: d(ms)) }
	public static func date(_ ms: Int64) -> String { dateF.string(from: d(ms)) }
	public static func dateTime(_ ms: Int64) -> String { dateTimeF.string(from: d(ms)) }

	/// "Title, 18:00 to 18:30": one phrase a screen reader reads cleanly.
	public static func programme(_ p: Programme) -> String {
		String(format: T("programme_times", "%1$@, %2$@ to %3$@"), p.title, time(p.start), time(p.stop))
	}

	/// Joins phrases with ". " without doubling the stop after times like "8:00 p.m.".
	public static func sentences(_ parts: [String]) -> String {
		let kept = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.trimmingCharacters(in: .whitespaces) }
		guard var out = kept.first else { return "" }
		for p in kept.dropFirst() { out = "\(out.trimmingSuffix(".")). \(p)" }
		return out
	}
}
