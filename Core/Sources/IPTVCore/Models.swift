import Foundation

/// Text the core shows the user (account info, episode names). The app points this at its
/// Localizable.strings; tests keep the English default.
public enum Strings {
	public static var localize: (_ key: String, _ english: String) -> String = { _, english in english }
}

func T(_ key: String, _ english: String) -> String { Strings.localize(key, english) }

/// A playlist source. M3U uses [url]; Xtream uses [url] as the server address.
/// JSON keys match the Android app, so its exported settings import here.
public struct Source: Codable, Hashable, Identifiable {
	public var id: String
	public var type: String // "m3u", "xtream" or "stalker"
	public var name: String
	public var url: String
	public var username: String
	public var password: String
	public var epgUrl: String
	public var mac: String

	public static let typeM3U = "m3u"
	public static let typeXtream = "xtream"
	public static let typeStalker = "stalker"

	public init(id: String, type: String, name: String, url: String, username: String = "", password: String = "", epgUrl: String = "", mac: String = "") {
		self.id = id; self.type = type; self.name = name; self.url = url
		self.username = username; self.password = password; self.epgUrl = epgUrl; self.mac = mac
	}

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 } ?? "" }
		id = try c.decode(String.self, forKey: .id)
		type = try c.decode(String.self, forKey: .type)
		name = s(.name); url = s(.url); username = s(.username); password = s(.password); epgUrl = s(.epgUrl); mac = s(.mac)
	}

	public var isXtream: Bool { type == Source.typeXtream }
	/// Guide URLs and display labels can change without replacing the channel catalogue.
	public func refersToSamePlaylist(as other: Source) -> Bool {
		id == other.id && type == other.type && url == other.url
			&& username == other.username && password == other.password && mac == other.mac
	}

	public static func samePlaylists(_ a: [Source], _ b: [Source]) -> Bool {
		a.count == b.count && zip(a, b).allSatisfy { pair in pair.0.refersToSamePlaylist(as: pair.1) }
	}
	public var isStalker: Bool { type == Source.typeStalker }
	/// An M3U file the user picked; its bookmark lives in [url].
	public var isFile: Bool { url.hasPrefix(Source.fileScheme) }
	public static let fileScheme = "file-bookmark:"

	/// The guide to import: the user's own, else the one Xtream servers publish.
	public var effectiveEpgUrl: String {
		if !epgUrl.trimmingCharacters(in: .whitespaces).isEmpty { return epgUrl }
		if isXtream { return "\(url.trimmingSuffix("/"))/xmltv.php?username=\(Source.enc(username))&password=\(Source.enc(password))" }
		if isStalker { return Stalker.baseUrl(url) + "/xmltv.php" }
		return ""
	}

	/// A URL path segment: only unreserved characters kept, so a space is %20, not "+".
	/// (The Android app form-encodes path segments; a password with a space or "+" broke there.)
	public static func pathEnc(_ s: String) -> String {
		var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
		allowed.insert(charactersIn: "-._~")
		return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
	}

	/// Form encoding as java.net.URLEncoder does it: space is "+", only A-Z a-z 0-9 . - * _ kept.
	public static func enc(_ s: String) -> String {
		var out = ""
		for b in s.utf8 {
			switch b {
			case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
				out.append(Character(UnicodeScalar(b)))
			case UInt8(ascii: " "): out.append("+")
			default: out += String(format: "%%%02X", b)
			}
		}
		return out
	}
}

/// One list entry: a live channel, a movie, a show or an episode. [attrs] keeps the M3U
/// attributes the catch-up rules need (catchup, catchup-source, catchup-days, timeshift, ...).
public struct Channel: Hashable, Identifiable {
	public let sourceId: String
	/// The provider's id for this entry (Android: Channel.id); never list position.
	public let itemId: String
	public let name: String
	public let group: String
	public let url: String
	public let tvgId: String
	public let logo: String
	public let attrs: [String: String]
	public let kind: String
	/// "source:item". Stored, not computed: SwiftUI reads it for every row on every list diff.
	public let key: String

	public init(sourceId: String, itemId: String, name: String, group: String, url: String, tvgId: String = "", logo: String = "", attrs: [String: String] = [:], kind: String = Channel.kindLive) {
		self.sourceId = sourceId; self.itemId = itemId; self.name = name; self.group = group; self.url = url
		self.tvgId = tvgId; self.logo = logo; self.attrs = attrs; self.kind = kind
		key = "\(sourceId):\(itemId)"
	}

	public var id: String { key }
	public var isLive: Bool { kind == Channel.kindLive }

	/// Stalker links are issued per play; [Library.resolveUrl] turns this into a real URL.
	public var needsResolve: Bool { url.hasPrefix(Channel.stalkerScheme) }

	public var catchupDays: Int {
		guard let v = attrs["catchup-days"] ?? attrs["timeshift"], let d = Double(v.trimmingCharacters(in: .whitespaces)) else { return 0 }
		return Int(d)
	}

	/// The provider's channel number (M3U tvg-chno, Xtream num, Stalker number), or "".
	public var number: String { attrs[Channel.chno] ?? "" }

	public var hasCatchup: Bool {
		!(attrs["catchup"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
			|| !(attrs["catchup-source"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
			|| catchupDays > 0
	}

	public static let kindLive = "live"
	public static let kindMovie = "movie"
	public static let kindSeries = "series" // a show; its episodes come from the provider on demand
	public static let kindEpisode = "episode"
	public static let stalkerScheme = "stalker:"
	public static let chno = "tvg-chno"

	/// "Go to channel number": the provider's number first, else the [n]th entry, like the desktop.
	public static func byNumber(_ list: [Channel], _ n: String) -> Channel? {
		guard let num = Int(n.trimmingCharacters(in: .whitespaces)), num > 0 else { return nil }
		if let hit = list.first(where: { Int($0.number) == num }) { return hit }
		return num - 1 < list.count ? list[num - 1] : nil
	}
}

/// Cache form, same short keys as the Android app's JSON cache.
extension Channel: Codable {
	enum CodingKeys: String, CodingKey { case s, i, n, g, u, t, l, a, k }

	public init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			sourceId: try c.decode(String.self, forKey: .s),
			itemId: try c.decode(String.self, forKey: .i),
			name: try c.decode(String.self, forKey: .n),
			group: try c.decodeIfPresent(String.self, forKey: .g) ?? "",
			url: try c.decode(String.self, forKey: .u),
			tvgId: try c.decodeIfPresent(String.self, forKey: .t) ?? "",
			logo: try c.decodeIfPresent(String.self, forKey: .l) ?? "",
			attrs: try c.decodeIfPresent([String: String].self, forKey: .a) ?? [:],
			kind: try c.decodeIfPresent(String.self, forKey: .k) ?? Channel.kindLive
		)
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(sourceId, forKey: .s); try c.encode(itemId, forKey: .i); try c.encode(name, forKey: .n)
		try c.encode(group, forKey: .g); try c.encode(url, forKey: .u); try c.encode(kind, forKey: .k)
		if !tvgId.isEmpty { try c.encode(tvgId, forKey: .t) }
		if !logo.isEmpty { try c.encode(logo, forKey: .l) }
		if !attrs.isEmpty { try c.encode(attrs, forKey: .a) }
	}
}

/// A guide entry. Times are epoch milliseconds, UTC.
public struct Programme: Hashable {
	public let channelKey: String
	public let start: Int64
	public let stop: Int64
	public let title: String
	public let description: String
	public let channelName: String

	public init(channelKey: String, start: Int64, stop: Int64, title: String, description: String = "", channelName: String = "") {
		self.channelKey = channelKey; self.start = start; self.stop = stop; self.title = title
		self.description = description; self.channelName = channelName
	}
}

/// Epoch milliseconds now.
public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

extension String {
	func trimmingSuffix(_ ch: Character) -> String {
		var s = Substring(self)
		while s.last == ch { s = s.dropLast() }
		return String(s)
	}

	func trimmingChars(_ set: Set<Character>) -> String {
		var s = Substring(self)
		while let f = s.first, set.contains(f) { s = s.dropFirst() }
		while let l = s.last, set.contains(l) { s = s.dropLast() }
		return String(s)
	}

	/// Case-insensitive prefix test, like Kotlin's startsWith(prefix, ignoreCase = true).
	func hasPrefixCI(_ p: String) -> Bool { lowercased().hasPrefix(p.lowercased()) }
	func hasSuffixCI(_ p: String) -> Bool { lowercased().hasSuffix(p.lowercased()) }
	func containsCI(_ p: String) -> Bool { range(of: p, options: .caseInsensitive) != nil }

	/// Text before the first [sep], or the whole string.
	func before(_ sep: Character) -> String { firstIndex(of: sep).map { String(self[..<$0]) } ?? self }
	func after(_ sep: Character) -> String { firstIndex(of: sep).map { String(self[index(after: $0)...]) } ?? self }
	func beforeLast(_ sep: Character) -> String { lastIndex(of: sep).map { String(self[..<$0]) } ?? self }
	func afterLast(_ sep: Character) -> String { lastIndex(of: sep).map { String(self[index(after: $0)...]) } ?? self }
}

/// List rules the Library uses; kept out of it so they test without SQLite.
public enum Lists {
	/// An M3U link from an Xtream panel (get.php?username=...) has an account behind it.
	public static func xtreamBehind(_ src: Source) -> Source? {
		if src.isXtream || src.isStalker { return nil }
		guard let c = Xtream.credentialsFromUrl(src.url) else { return nil }
		var x = src
		x.type = Source.typeXtream; x.url = c.server; x.username = c.user; x.password = c.pass
		return x
	}

	/// Port of the desktop's search_rank; the sort is stable, so ties keep playlist order.
	public static func searchRanked(_ list: [Channel], _ q: String) -> [Channel] {
		ranked(list, list.map { lowerName($0.name) }, q)
	}

	/// The form names are searched in; the Library keeps one per entry so a keystroke does not
	/// lowercase 250,000 names again. Composed: the byte scan in [firstHit] only finds a query in
	/// a name that is written the same way, and feeds carry decomposed text.
	public static func lowerName(_ s: String) -> String {
		s.trimmingCharacters(in: .whitespaces).lowercased().precomposedStringWithCanonicalMapping
	}

	/// [searchRanked] over names already in [lowerName] form (same order as [list]).
	public static func ranked(_ list: [Channel], _ lower: [String], _ q: String) -> [Channel] {
		let query = lowerName(q)
		if query.isEmpty { return list }
		var hits: [(r: Int, n: Int, i: Int)] = []
		for i in list.indices {
			let n = lower[i]
			if let r = rank(n, query) { hits.append((r, n.count, i)) }
		}
		return hits.sorted { ($0.r, $0.n, $0.i) < ($1.r, $1.n, $1.i) }.map { list[$0.i] }
	}

	/// nil when [query] is not in [n]; else 0 exact, 1 at a word start, 2 inside a word.
	private static func rank(_ n: String, _ query: String) -> Int? {
		if n == query { return 0 }
		guard var hit = firstHit(n, query) else { return nil }
		while true {
			if hit == n.startIndex { return 1 }
			let before = n[n.index(before: hit)]
			if !(before.isLetter || before.isNumber) { return 1 }
			guard let next = n.range(of: query, range: n.index(after: hit)..<n.endIndex) else { return 2 }
			hit = next.lowerBound
		}
	}

	/// First occurrence of [query] in [n] (both already lowercased). Foundation's substring search
	/// costs about 30x a byte scan over 50,000 names, which is one keystroke's work in the app. A
	/// UTF-8 needle can only match on a character boundary, so scanning bytes finds the same hit.
	private static func firstHit(_ n: String, _ query: String) -> String.Index? {
		let q = [UInt8](query.utf8)
		let found: Int?? = n.utf8.withContiguousStorageIfAvailable { buf -> Int? in
			guard buf.count >= q.count else { return nil }
			let last = buf.count - q.count
			var i = 0
			while i <= last {
				if buf[i] == q[0] {
					var j = 1
					while j < q.count, buf[i + j] == q[j] { j += 1 }
					if j == q.count { return i }
				}
				i += 1
			}
			return nil
		}
		// No contiguous bytes to scan (a bridged string): fall back to the ICU search.
		guard let found else { return n.range(of: query)?.lowerBound }
		guard let off = found else { return nil }
		guard let idx = String.Index(n.utf8.index(n.utf8.startIndex, offsetBy: off), within: n) else {
			return n.range(of: query)?.lowerBound
		}
		return idx
	}

}
