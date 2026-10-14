import Foundation

/// The raw parts of an absolute URL, as java.net.URI gives them (still percent-encoded).
struct RawURL {
	let scheme: String
	let authority: String
	let path: String
	let query: String?

	init?(_ s: String) {
		guard let sep = s.range(of: "://") else { return nil }
		let scheme = String(s[..<sep.lowerBound])
		guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
		var rest = Substring(s[sep.upperBound...])
		if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
		let authEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
		let authority = String(rest[..<authEnd])
		guard !authority.isEmpty, !authority.contains(" ") else { return nil }
		let tail = rest[authEnd...]
		if let q = tail.firstIndex(of: "?") {
			path = String(tail[..<q]); query = String(tail[tail.index(after: q)...])
		} else {
			path = String(tail); query = nil
		}
		guard !path.contains(" ") else { return nil }
		self.scheme = scheme
		self.authority = authority
	}
}

/// Catch-up (archive) URLs, ported from the desktop client's rules.
public enum Catchup {
	private static let tokens: [(String, String)] = [
		("${start}", "start"), ("${timestamp}", "lutc"), ("${duration}", "duration"), ("${end}", "end"),
		("{utc}", "start"), ("{lutc}", "lutc"), ("{utcstart}", "start"), ("{utcend}", "end"),
		("{duration}", "duration"), ("{S}", "start"), ("{E}", "end"), ("{L}", "lutc"), ("{D}", "duration"),
		("{Y}", "Y"), ("{m}", "m"), ("{d}", "d"), ("{H}", "H"), ("{M}", "M"),
		("{y}", "eY"), ("{e}", "ed"), ("{h}", "eH"), ("{i}", "eM"),
	]
	private static let xtreamLive = try! NSRegularExpression(pattern: #"^/(?:live/)?([^/]+)/([^/]+)/(\d+)(?:\.[A-Za-z0-9]+)?$"#)

	/// True when [startMs] is inside the channel's archive window (no window = allowed).
	public static func withinWindow(_ ch: Channel, _ startMs: Int64, now: Int64 = nowMs()) -> Bool {
		let days = ch.catchupDays
		return days <= 0 || startMs >= now - Int64(days) * 86_400_000
	}

	/// The archive URL for a past programme, or nil when the channel cannot provide one.
	public static func url(_ ch: Channel, _ startMs: Int64, _ endMs: Int64, zone: TimeZone = .current, now: Int64 = nowMs()) -> String? {
		let offsetMs = Int64((Double(ch.attrs["catchup-offset"] ?? "") ?? 0) * 3_600_000)
		let start = startMs - offsetMs
		let end = endMs - offsetMs
		let durationMin = max(1, (endMs - startMs) / 60_000)
		let source = (ch.attrs["catchup-source"] ?? "").trimmingCharacters(in: .whitespaces)
		let base: String
		let headerTail: String
		if let bar = ch.url.firstIndex(of: "|") { base = String(ch.url[..<bar]); headerTail = String(ch.url[bar...]) } else { base = ch.url; headerTail = "" }

		if source.isEmpty {
			guard (ch.attrs["catchup"] ?? "").caseInsensitiveCompare("xc") == .orderedSame, let uri = RawURL(base) else { return nil }
			let path = uri.path as NSString
			guard let m = xtreamLive.firstMatch(in: uri.path, range: NSRange(location: 0, length: path.length)) else { return nil }
			let user = path.substring(with: m.range(at: 1)), pass = path.substring(with: m.range(at: 2)), id = path.substring(with: m.range(at: 3))
			let token = tokenFormat(wallClock(start, ch, zone))
			let query = uri.query.map { "?\($0)" } ?? ""
			return "\(uri.scheme)://\(uri.authority)/timeshift/\(user)/\(pass)/\(durationMin)/\(token)/\(id).ts\(query)\(headerTail)"
		}

		if tokens.contains(where: { source.contains($0.0) }) {
			var expanded = source
			for (t, kind) in tokens { expanded = expanded.replacingOccurrences(of: t, with: value(kind, start, end, now, zone)) }
			// catchup="default": the template is the whole archive URL, not a tail for the live one.
			if expanded.hasPrefixCI("http://") || expanded.hasPrefixCI("https://") { return expanded + headerTail }
			if base.contains("?") && expanded.hasPrefix("?") { expanded = "&" + expanded.dropFirst() }
			return base + expanded + headerTail
		}

		// Path style: <source>/<stream id>/<start>/<duration>/.
		var src = source.trimmingSuffix("/")
		if !src.afterLast("/").allSatisfy(\.isNumber) {
			let id = base.trimmingSuffix("/").afterLast("/").before(".")
			if id.isEmpty { return nil }
			src = "\(src)/\(id)"
		}
		let startLocal = wallClock(start, ch, zone)
		let type = (ch.attrs["catchup-type"] ?? ch.attrs["catchup"] ?? "xc").lowercased()
		let u: String
		if type == "flussonic" {
			let p = startLocal
			u = "\(src)/" + String(format: "%04d%02d%02d%02d%02d%02d", p.year, p.month, p.day, p.hour, p.minute, p.second) + "-\(durationMin).m3u8"
		} else {
			u = "\(src)/\(tokenFormat(startLocal))/\(durationMin)/"
		}
		return u + headerTail
	}

	struct Wall { let year, month, day, hour, minute, second: Int }

	static func wall(_ ms: Int64, _ tz: TimeZone) -> Wall {
		var cal = Calendar(identifier: .gregorian)
		cal.timeZone = tz
		let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
		return Wall(year: c.year!, month: c.month!, day: c.day!, hour: c.hour!, minute: c.minute!, second: c.second!)
	}

	private static func tokenFormat(_ w: Wall) -> String {
		String(format: "%04d-%02d-%02d:%02d-%02d", w.year, w.month, w.day, w.hour, w.minute)
	}

	/// Archive start on the provider's clock: "UTC" (Dispatcharr), an IANA zone, else local.
	private static func wallClock(_ ms: Int64, _ ch: Channel, _ zone: TimeZone) -> Wall {
		let tz = (ch.attrs["catchup-timezone"] ?? "").trimmingCharacters(in: .whitespaces)
		let z: TimeZone
		switch tz {
		case "": z = zone
		case "UTC", "GMT", "Z", "Etc/UTC": z = TimeZone(identifier: "UTC")!
		default: z = TimeZone(identifier: tz) ?? zone
		}
		return wall(ms, z)
	}

	private static func value(_ kind: String, _ start: Int64, _ end: Int64, _ now: Int64, _ zone: TimeZone) -> String {
		let s = wall(start, zone), e = wall(end, zone)
		switch kind {
		case "start": return String(start / 1000)
		case "end": return String(end / 1000)
		case "lutc": return String(now / 1000)
		case "duration": return String(max(1, (end - start) / 1000))
		case "Y": return String(format: "%04d", s.year)
		case "m": return String(format: "%02d", s.month)
		case "d": return String(format: "%02d", s.day)
		case "H": return String(format: "%02d", s.hour)
		case "M": return String(format: "%02d", s.minute)
		case "eY": return String(format: "%04d", e.year)
		case "ed": return String(format: "%02d", e.day)
		case "eH": return String(format: "%02d", e.hour)
		case "eM": return String(format: "%02d", e.minute)
		default: return ""
		}
	}
}
