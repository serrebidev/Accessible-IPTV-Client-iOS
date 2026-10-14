import Foundation

/// Parses M3U / M3U Plus text into channels. Port of the Android M3uParser.
public enum M3U {
	// Quoted, single-quoted or bare values, like the desktop's _M3U_ATTR_RE.
	private static let attrRe = try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^",\s]+))"#)
	private static let keptAttrs: Set<String> = ["catchup", "catchup-source", "catchup-days", "catchup-timezone", "catchup-offset", "catchup-type", "timeshift", Channel.chno]

	/// Player options a playlist sets per channel, as HTTP headers. Same names as the desktop.
	private static let headerOpts: [String: String] = [
		"http-user-agent": "User-Agent", "http-referrer": "Referer", "http-referer": "Referer",
		"referer": "Referer", "referrer": "Referer", "http-origin": "Origin", "origin": "Origin",
		"http-cookie": "Cookie", "cookie": "Cookie",
	]

	/// Channel ids are tvg-id plus name, not list position: favourites, remembered audio
	/// tracks and scheduled recordings must still find the channel after the provider adds,
	/// drops or reorders entries. A repeated name gets "#2", "#3".
	public static func parse(sourceId: String, text: String) -> [Channel] {
		var out: [Channel] = []
		var seen: [String: Int] = [:]
		var header: [String: String] = [:]
		var entry: [String: String]?
		var opts: [String: String] = [:]
		var name = ""
		var extGrp = ""
		let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
		for raw in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty { continue }
			if line.hasPrefixCI("#EXTM3U") {
				header = attributes(line)
			} else if line.hasPrefixCI("#EXTINF") {
				let comma = titleComma(line)
				let attrPart = comma.map { String(line[..<$0]) } ?? line
				let e = attributes(attrPart)
				entry = e
				name = comma.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
				opts = [:]
				for (k, v) in e { if let h = headerOpts[k] { opts[h] = v } }
			} else if line.hasPrefixCI("#EXTGRP:") {
				extGrp = line.after(":").trimmingCharacters(in: .whitespaces)
			} else if line.hasPrefixCI("#EXTVLCOPT:") || line.hasPrefixCI("#KODIPROP:") {
				let kv = line.after(":")
				let k = kv.before("=").trimmingCharacters(in: .whitespaces).lowercased()
				if kv.contains("="), let h = headerOpts[k] { opts[h] = kv.after("=").trimmingCharacters(in: .whitespaces) }
			} else if line.hasPrefix("#") {
				continue
			} else if let e = entry {
				// Playlist-wide catch-up settings apply to channels without their own.
				var attrs = header.filter { keptAttrs.contains($0.key) }
				for (k, v) in e where keptAttrs.contains(k) { attrs[k] = v }
				var title = name
				if title.isEmpty { title = e["tvg-name"] ?? "" }
				if title.isEmpty { title = line }
				let tvgId = e["tvg-id"] ?? ""
				let base = "\(tvgId)|\(title)"
				let n = (seen[base] ?? 0) + 1
				seen[base] = n
				var group = e["group-title"] ?? ""
				if group.isEmpty { group = extGrp }
				if group.isEmpty { group = "Ungrouped" }
				out.append(Channel(
					sourceId: sourceId,
					itemId: n == 1 ? base : "\(base)#\(n)",
					name: title,
					group: group,
					url: withHeaders(line, opts),
					tvgId: tvgId,
					logo: e["tvg-logo"] ?? "",
					attrs: attrs,
					kind: kindOf(url: line, tvgType: e["tvg-type"] ?? "")
				))
				entry = nil
				extGrp = ""
			}
		}
		return out
	}

	/// Guide URLs the #EXTM3U header names (x-tvg-url / url-tvg, comma separated). http(s) only.
	public static func headerGuides(_ text: String) -> [String] {
		var t = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
		t = String(t.drop(while: { $0.isWhitespace }))
		let first = String(t.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
		guard first.hasPrefixCI("#EXTM3U") else { return [] }
		let attrs = attributes(first)
		var raw: String?
		for k in ["x-tvg-url", "url-tvg"] {
			guard let v = attrs[k] else { continue }
			// A bare (unquoted) list stops at the first comma in the regex; take it to the next space.
			let re = try! NSRegularExpression(pattern: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: k) + #"\s*=\s*([^"'\s]\S*)"#)
			if let m = re.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)), let r = Range(m.range(at: 1), in: first) {
				raw = String(first[r])
			} else {
				raw = v
			}
			break
		}
		guard let list = raw else { return [] }
		var out: [String] = []
		for part in list.split(separator: ",", omittingEmptySubsequences: false) {
			let u = part.trimmingCharacters(in: .whitespaces)
			guard u.hasPrefixCI("http://") || u.hasPrefixCI("https://") else { continue }
			let fixed = u.before(":").lowercased() + "://" + String(u[u.range(of: "://")!.upperBound...])
			if !out.contains(fixed) { out.append(fixed) }
		}
		return out
	}

	/// Xtream-style M3U files mark VOD by path: /movie/ and /series/.
	public static func kindOf(url: String, tvgType: String) -> String {
		if tvgType.caseInsensitiveCompare("movie") == .orderedSame || url.contains("/movie/") { return Channel.kindMovie }
		if tvgType.caseInsensitiveCompare("series") == .orderedSame || url.contains("/series/") { return Channel.kindEpisode }
		return Channel.kindLive
	}

	public static func attributes(_ line: String) -> [String: String] {
		var out: [String: String] = [:]
		let ns = line as NSString
		for m in attrRe.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
			let k = ns.substring(with: m.range(at: 1)).lowercased()
			for g in 2...4 where m.range(at: g).location != NSNotFound {
				out[k] = ns.substring(with: m.range(at: g))
				break
			}
		}
		return out
	}

	/// Index of the comma that starts the title: the first one outside quotes.
	private static func titleComma(_ line: String) -> String.Index? {
		var inQuotes = false
		var i = line.startIndex
		while i < line.endIndex {
			let c = line[i]
			if c == "\"" { inQuotes.toggle() } else if c == "," && !inQuotes { return i }
			i = line.index(after: i)
		}
		return nil
	}

	/// Adds playlist headers to the URL's "|Key=Value" tail; ones already in the tail win.
	private static func withHeaders(_ url: String, _ opts: [String: String]) -> String {
		if opts.isEmpty { return url }
		let (plain, existing) = splitHeaders(url)
		var merged = opts
		for (k, v) in existing { merged[k] = v }
		// Sorted so the same playlist always gives the same URL (Kotlin kept insertion order).
		return plain + "|" + merged.keys.sorted().map { "\($0)=\(Source.enc(merged[$0]!))" }.joined(separator: "&")
	}

	/// Splits Kodi-style "url|User-Agent=x&Referer=y" into the URL and its headers.
	public static func splitHeaders(_ url: String) -> (String, [String: String]) {
		guard let bar = url.firstIndex(of: "|") else { return (url, [:]) }
		var headers: [String: String] = [:]
		for part in url[url.index(after: bar)...].split(separator: "&", omittingEmptySubsequences: false) {
			guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { continue }
			var k = part[..<eq].trimmingCharacters(in: .whitespaces)
			if k.caseInsensitiveCompare("UA") == .orderedSame { k = "User-Agent" }
			let raw = String(part[part.index(after: eq)...])
			headers[k] = formDecode(raw) ?? raw
		}
		return (String(url[..<bar]), headers)
	}

	/// java.net.URLDecoder.decode: "+" is a space; a broken escape is nil (caller keeps the raw text).
	static func formDecode(_ s: String) -> String? {
		s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
	}
}
