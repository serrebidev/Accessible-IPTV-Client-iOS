import Foundation

/// New-version check against GitHub Releases. iOS installs come from AltStore (or another
/// sideloading tool), so the app only says that a version is out and opens AltStore.
public enum Updater {
	public static let repo = "serrebidev/Accessible-IPTV-Client-iOS"
	/// The AltStore source this app is published in.
	public static let altSource = "https://raw.githubusercontent.com/serrebidev/serrebiALT/main/apps.json"

	public struct Release {
		public let version: String
		public let notes: String
		public let page: String
	}

	/// The newer release, or nil when this build is current.
	public static func check(current: String) async throws -> Release? {
		let o = try JSONDecoder().decode(JSONValue.self, from: try await Net.data("https://api.github.com/repos/\(repo)/releases/latest"))
		let tag = o["tag_name"]?.text ?? ""
		let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
		guard isNewer(version, current) else { return nil }
		return Release(version: version, notes: (o["body"]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
			page: o["html_url"]?.text ?? "https://github.com/\(repo)/releases/latest")
	}

	/// Numeric compare of dotted versions: "0.10.0" is newer than "0.9.3".
	public static func isNewer(_ candidate: String, _ current: String) -> Bool {
		func parts(_ v: String) -> [Int] { v.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 } }
		let a = parts(candidate), b = parts(current)
		for i in 0..<max(a.count, b.count) {
			let d = (i < a.count ? a[i] : 0) - (i < b.count ? b[i] : 0)
			if d != 0 { return d > 0 }
		}
		return false
	}
}

/// Timed text from an SRT or WebVTT file, for subtitle speech (desktop subtitle_cues.py).
/// libVLC renders subtitles but never hands their text over, so the player reads the file
/// it loaded itself and looks cues up against the media clock.
public enum SubtitleCues {
	public struct Cue: Equatable {
		public let start: Int64 // ms
		public let end: Int64
		public let text: String
	}

	private static let timing = try! NSRegularExpression(pattern: #"(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})"#)
	private static let tag = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)

	public static let speakableExtensions: Set<String> = ["srt", "vtt"]

	/// Cues sorted by start time; blocks without a timing line are skipped.
	public static func parse(_ raw: String) -> [Cue] {
		let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		var blocks: [[String]] = [[]]
		for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
			if line.trimmingCharacters(in: .whitespaces).isEmpty {
				if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
			} else {
				blocks[blocks.count - 1].append(String(line))
			}
		}
		var cues: [Cue] = []
		for lines in blocks {
			for (i, line) in lines.enumerated() {
				let ns = line as NSString
				guard let m = timing.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
				func g(_ k: Int) -> String { m.range(at: k).location == NSNotFound ? "" : ns.substring(with: m.range(at: k)) }
				func ms(_ h: String, _ mi: String, _ s: String, _ frac: String) -> Int64 {
					let f = frac.padding(toLength: 3, withPad: "0", startingAt: 0)
					return ((Int64(h) ?? 0) * 3600 + (Int64(mi) ?? 0) * 60 + (Int64(s) ?? 0)) * 1000 + (Int64(f) ?? 0)
				}
				let body = lines[(i + 1)...].map { part -> String in
					let p = part as NSString
					return XmlPull.decodeEntities(tag.stringByReplacingMatches(in: part, range: NSRange(location: 0, length: p.length), withTemplate: "")).trimmingCharacters(in: .whitespaces)
				}.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
				let start = ms(g(1), g(2), g(3), g(4)), end = ms(g(5), g(6), g(7), g(8))
				if !body.isEmpty && end > start { cues.append(Cue(start: start, end: end, text: body)) }
				break
			}
		}
		return cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
	}

	/// Index of the latest cue that has started by [ms], shown or not.
	public static func started(_ cues: [Cue], _ ms: Int64) -> Int? {
		var lo = 0, hi = cues.count
		while lo < hi { let mid = (lo + hi) / 2; if cues[mid].start <= ms { lo = mid + 1 } else { hi = mid } }
		return lo > 0 ? lo - 1 : nil
	}

	/// Index of the cue showing at [ms]; the latest-starting one wins on overlap.
	public static func active(_ cues: [Cue], _ ms: Int64) -> Int? {
		guard var i = started(cues, ms) else { return nil }
		while i >= 0 && cues[i].start <= ms {
			if ms < cues[i].end { return i }
			if ms - cues[i].start > 3_600_000 { break } // ponytail: linear back-scan for overlaps, bounded to an hour
			i -= 1
		}
		return nil
	}
}
