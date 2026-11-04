import Foundation

/// The time questions Siri and Shortcuts ask of a guide: what is on later, what is on at eight,
/// and when a recording should run. Pure so the rules are testable away from the guide database.
public enum GuideWindow {
	/// How far ahead "later" looks when the request names no end.
	public static let defaultSpanMs: Int64 = 12 * 3_600_000

	/// The range a schedule query reads. No start means from now; no end means twelve hours on.
	/// A reversed range (Siri heard "until 8" after 8) collapses to the default span.
	public static func range(from: Int64?, to: Int64?, now: Int64) -> (from: Int64, to: Int64) {
		let start = from ?? now
		let end = to ?? start + defaultSpanMs
		return (start, end > start ? end : start + defaultSpanMs)
	}

	/// Programmes for "what is on": at a named time, whatever overlaps it, including the
	/// programme already running then. With no time named, "later" means what starts after
	/// now, so the answer is not the programme the person is asking past.
	public static func schedule(_ list: [Programme], from: Int64?, to: Int64?, now: Int64, limit: Int) -> [Programme] {
		let window = range(from: from, to: to, now: now)
		let kept = list.filter { p in
			guard p.start < window.to, p.stop > window.from else { return false }
			return from != nil || p.start > now
		}
		return Array(kept.sorted { $0.start < $1.start }.prefix(max(0, limit)))
	}

	/// Guide search results narrowed by a time range and a channel group, both optional.
	public static func filter(_ pairs: [(Programme, Channel)], from: Int64?, to: Int64?, group: String?) -> [(Programme, Channel)] {
		let wanted = group?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return pairs.filter { p, ch in
			if let from, p.stop <= from { return false }
			if let to, p.start >= to { return false }
			return wanted.isEmpty || ch.group.localizedCaseInsensitiveContains(wanted)
		}
	}

	/// Puts favourite channels first and keeps the order otherwise.
	public static func favoritesFirst(_ pairs: [(Programme, Channel)], favorites: Set<String>) -> [(Programme, Channel)] {
		pairs.filter { favorites.contains($0.1.key) } + pairs.filter { !favorites.contains($0.1.key) }
	}

	/// The window a recording asked for by time runs in. No end means [defaultMinutes] from
	/// the start. Nil when it would already be over or runs backwards: never a silent no-op.
	public static func recording(start: Int64, end: Int64?, defaultMinutes: Int = 60, now: Int64) -> (start: Int64, end: Int64)? {
		let stop = end ?? start + Int64(max(1, defaultMinutes)) * 60_000
		guard stop > start, stop > now else { return nil }
		return (start, stop)
	}

	/// Whether a list already holds a recording of this channel overlapping this window.
	/// A retried Siri request must not schedule the same programme twice.
	public static func alreadyScheduled(_ list: [Recording.Scheduled], channelKey: String, start: Int64, end: Int64) -> Bool {
		list.contains { $0.channelKey == channelKey && $0.start < end && $0.end > start }
	}

	/// Clock position after a relative skip, kept inside the file: nil when there is nothing
	/// to do, so a skip past the start at the start says nothing rather than restarting.
	public static func skipped(from position: Double, by seconds: Double) -> Double? {
		guard position.isFinite, seconds.isFinite, seconds != 0 else { return nil }
		let target = max(0, position + seconds)
		return target == position ? nil : target
	}

	/// The lines of an account answer a voice assistant may read out. Only status and expiry:
	/// account details stay on the Account screen.
	public static func accountSummary(_ rows: [(String, String)]) -> [String] {
		rows.prefix(2).map { "\($0.0): \($0.1)" }
	}
}
