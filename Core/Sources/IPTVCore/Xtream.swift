import Foundation

/// Xtream Codes player_api client: live channels, VOD, series and account info.
public enum Xtream {
	/// Server address as the API wants it. People paste whatever the panel gave them:
	/// "host:8080", ".../player_api.php", or a whole get.php M3U link. Query and endpoint go.
	public static func normalizeServer(_ s: String) -> String {
		var t = s.trimmingCharacters(in: .whitespacesAndNewlines).before("?").before("#").trimmingSuffix("/")
		if t.afterLast("/").hasSuffixCI(".php") { t = t.beforeLast("/") }
		return withScheme(t)
	}

	/// Trimmed, no trailing slash, http:// added when no scheme was typed. Stalker keeps its endpoint path.
	public static func withScheme(_ s: String) -> String {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingSuffix("/")
		return t.hasPrefixCI("http://") || t.hasPrefixCI("https://") ? t : "http://\(t)"
	}

	private static let streamId = try! NSRegularExpression(pattern: #"^\d+(?:\.[A-Za-z0-9]+)?$"#)
	private static let streamPrefixes: Set<String> = ["live", "movie", "series", "timeshift"]

	/// (server, username, password) when [url] is an Xtream panel link: get.php / player_api.php
	/// with username and password, or a stream path /live/U/P/123.ts. Port of the desktop's
	/// xtream_credentials_from_url: a false match would show an account that does not exist.
	public static func credentialsFromUrl(_ url: String) -> (server: String, user: String, pass: String)? {
		guard let u = RawURL(url.trimmingCharacters(in: .whitespaces).before("|")),
		      ["http", "https"].contains(u.scheme.lowercased()) else { return nil }
		let root = "\(u.scheme)://\(u.authority)"
		let segs = u.path.split(separator: "/").map(String.init)
		func dec(_ s: String) -> String { (M3U.formDecode(s) ?? s).trimmingCharacters(in: .whitespaces) }
		if let q = u.query, segs.last?.hasSuffixCI(".php") == true {
			var params: [String: String] = [:]
			for part in q.split(separator: "&", omittingEmptySubsequences: false) {
				let p = String(part)
				params[dec(p.before("="))] = p.contains("=") ? dec(p.after("=")) : ""
			}
			let user = params["username"] ?? "", pass = params["password"] ?? ""
			if !user.isEmpty && !pass.isEmpty { return (([root] + segs.dropLast()).joined(separator: "/"), user, pass) }
		}
		if segs.count >= 3, let last = segs.last, streamId.firstMatch(in: last, range: NSRange(location: 0, length: (last as NSString).length)) != nil {
			let first = segs[0].lowercased()
			let offset: Int
			if segs.count == 3 && !streamPrefixes.contains(first) { offset = 0 }
			else if segs.count == 4 && streamPrefixes.contains(first) { offset = 1 }
			else if segs.count == 6 && first == "timeshift" { offset = 1 }
			else { return nil }
			// Path segments: %20 is a space, "+" is a plus (unlike the query above).
			func pdec(_ s: String) -> String { (s.removingPercentEncoding ?? s).trimmingCharacters(in: .whitespaces) }
			let user = pdec(segs[offset]), pass = pdec(segs[offset + 1])
			if !user.isEmpty && !pass.isEmpty { return (root, user, pass) }
		}
		return nil
	}

	static func api(_ src: Source, _ action: String = "") -> String {
		"\(src.url)/player_api.php?username=\(Source.enc(src.username))&password=\(Source.enc(src.password))" + (action.isEmpty ? "" : "&action=\(action)")
	}

	public static func liveChannels(_ src: Source) async throws -> [Channel] {
		let cats = try await categories(src, "get_live_categories")
		var out: [Channel] = []
		try await Net.forEachObject(api(src, "get_live_streams")) { o in out.append(live(src, o, cats)) }
		return out
	}

	/// One get_live_streams entry. TS, not m3u8: some servers (Dispatcharr) answer m3u8 with HTTP 500.
	static func live(_ src: Source, _ o: [String: String], _ cats: [String: String]) -> Channel {
		let id = o["stream_id"] ?? ""
		var attrs: [String: String] = [:]
		if o["tv_archive"] == "1" { attrs["catchup"] = "xc"; attrs["catchup-days"] = o["tv_archive_duration"] ?? "" }
		if let n = o["num"], !n.trimmingCharacters(in: .whitespaces).isEmpty, n != "null" { attrs[Channel.chno] = n }
		let epg = o["epg_channel_id"]
		return Channel(
			sourceId: src.id, itemId: id, name: o["name"] ?? "", group: cats[o["category_id"] ?? ""] ?? ungrouped,
			url: "\(src.url)/live/\(Source.pathEnc(src.username))/\(Source.pathEnc(src.password))/\(id).ts",
			tvgId: epg == "null" ? "" : epg ?? "", attrs: attrs
		)
	}

	static let ungrouped = "Ungrouped"

	/// category_id -> name.
	private static func categories(_ src: Source, _ action: String) async throws -> [String: String] {
		var out: [String: String] = [:]
		try await Net.forEachObject(api(src, action)) { out[$0["category_id"] ?? ""] = $0["category_name"] ?? "" }
		return out
	}

	public static func movies(_ src: Source) async throws -> [Channel] {
		let cats = try await categories(src, "get_vod_categories")
		var out: [Channel] = []
		try await Net.forEachObject(api(src, "get_vod_streams")) { o in out.append(movie(src, o, cats)) }
		return out
	}

	static func movie(_ src: Source, _ o: [String: String], _ cats: [String: String]) -> Channel {
		let id = o["stream_id"] ?? ""
		let ext = (o["container_extension"] ?? "").isEmpty ? "mp4" : o["container_extension"]!
		return Channel(sourceId: src.id, itemId: "m\(id)", name: o["name"] ?? "", group: cats[o["category_id"] ?? ""] ?? ungrouped,
			url: "\(src.url)/movie/\(Source.pathEnc(src.username))/\(Source.pathEnc(src.password))/\(id).\(ext)", kind: Channel.kindMovie)
	}

	public static func series(_ src: Source) async throws -> [Channel] {
		let cats = try await categories(src, "get_series_categories")
		var out: [Channel] = []
		try await Net.forEachObject(api(src, "get_series")) { o in out.append(show(src, o, cats)) }
		return out
	}

	/// url holds the series id; episodes are fetched when the show is opened.
	static func show(_ src: Source, _ o: [String: String], _ cats: [String: String]) -> Channel {
		let plot = o["plot"] ?? ""
		return Channel(sourceId: src.id, itemId: "s\(o["series_id"] ?? "")", name: o["name"] ?? "", group: cats[o["category_id"] ?? ""] ?? ungrouped,
			url: o["series_id"] ?? "", attrs: plot.trimmingCharacters(in: .whitespaces).isEmpty ? [:] : ["plot": plot], kind: Channel.kindSeries)
	}

	private static let yearSuffix = try! NSRegularExpression(pattern: #"\s*\(\d{4}\)\s*$"#)
	private static let seasonEpisode = try! NSRegularExpression(pattern: #"(?i)\bS\d{1,3}\s*E\d{1,4}\b"#)

	/// Providers often title episodes "Show Name - S01E02"; after the season and episode
	/// are spoken, that is pure repetition. Keeps only a real episode title, else "".
	public static func episodeTitle(_ raw: String, show: String) -> String {
		var t = raw.trimmingCharacters(in: .whitespaces)
		let showBase = yearSuffix.stringByReplacingMatches(in: show, range: NSRange(location: 0, length: (show as NSString).length), withTemplate: "")
		for prefix in [show, showBase] where !prefix.isEmpty && t.hasPrefixCI(prefix) { t = String(t.dropFirst(prefix.count)) }
		t = seasonEpisode.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: "")
		return t.trimmingChars([" ", "-", ":", ".", "|", "_"])
	}

	/// Episodes of a show, in season order, named "Season 1, Episode 2: Title".
	public static func episodes(_ src: Source, show: Channel) async throws -> [Channel] {
		try parseEpisodes(src, show: show, body: try await Net.data(api(src, "get_series_info") + "&series_id=\(show.url)"))
	}

	/// get_series_info body -> episodes. "episodes" is keyed by season, or (some panels) a list of seasons.
	public static func parseEpisodes(_ src: Source, show: Channel, body: Data) throws -> [Channel] {
		guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: body) else { return [] }
		var seasons: [(String, [JSONValue])] = []
		switch root["episodes"] {
		case .object(let byKey)?:
			for k in byKey.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) { if case .array(let a)? = byKey[k] { seasons.append((k, a)) } }
		case .array(let list)?:
			for (i, v) in list.enumerated() { if case .array(let a) = v { seasons.append((String(i + 1), a)) } }
		default: break
		}
		var out: [Channel] = []
		for (season, list) in seasons {
			for (i, v) in list.enumerated() {
				guard case .object(let e) = v else { continue }
				let id = e["id"]?.text ?? ""
				if id.isEmpty { continue }
				let n = e["episode_num"]?.text ?? ""
				let num = n.isEmpty ? String(i + 1) : n
				let title = episodeTitle(e["title"]?.text ?? "", show: show.name)
				let x = e["container_extension"]?.text ?? ""
				let ext = x.isEmpty ? "mp4" : x
				let base = String(format: T("season_episode", "Season %1$@, Episode %2$@"), season, num)
				let label = title.isEmpty ? base : "\(base): \(title)"
				var plot = ""
				if case .object(let info)? = e["info"] { plot = info["plot"]?.text ?? "" }
				out.append(Channel(sourceId: src.id, itemId: "e\(id)", name: label, group: show.name,
					url: "\(src.url)/series/\(Source.pathEnc(src.username))/\(Source.pathEnc(src.password))/\(id).\(ext)",
					attrs: ["plot": plot], kind: Channel.kindEpisode))
			}
		}
		return out
	}

	/// user_info from the server, as label/value lines ready to read out.
	public static func accountInfo(_ src: Source) async throws -> [(String, String)] {
		try parseAccount(try await Net.data(api(src)))
	}

	public static func parseAccount(_ body: Data, now: Int64 = nowMs()) throws -> [(String, String)] {
		guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: body), case .object(let u)? = root["user_info"] else { return [] }
		func f(_ k: String) -> String { u[k]?.text ?? "" }
		var out: [(String, String)] = []
		out.append((T("account_status", "Status"), f("status")))
		if let exp = Int64(f("exp_date")) {
			let days = Int64((Double(exp * 1000 - now) / 86_400_000).rounded(.down))
			let date = Format.date(exp * 1000)
			out.append((T("account_expires", "Expires"), days < 0
				? String(format: T("account_expired_on", "%1$@, expired"), date)
				: String(format: T("account_days_left", "%1$@, %2$ld days left"), date, Int(days))))
		} else {
			out.append((T("account_expires", "Expires"), T("account_never", "Never")))
		}
		out.append((T("account_trial", "Trial"), f("is_trial") == "1" ? T("yes", "Yes") : T("no", "No")))
		out.append((T("account_connections", "Connections in use"), String(format: T("n_of_m", "%1$@ of %2$@"), f("active_cons"), f("max_connections"))))
		if let created = Int64(f("created_at")) { out.append((T("account_created", "Created"), Format.date(created * 1000))) }
		return out
	}
}

/// Any JSON value; scalars read back as text the way org.json's optString gives them.
enum JSONValue: Decodable {
	case string(String), number(String), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

	init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() { self = .null }
		else if let b = try? c.decode(Bool.self) { self = .bool(b) }
		else if let i = try? c.decode(Int64.self) { self = .number(String(i)) }
		else if let d = try? c.decode(Double.self) { self = .number(String(d)) }
		else if let s = try? c.decode(String.self) { self = .string(s) }
		else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
		else { self = .object(try c.decode([String: JSONValue].self)) }
	}

	var text: String {
		switch self {
		case .string(let s), .number(let s): return s
		case .bool(let b): return b ? "true" : "false"
		default: return ""
		}
	}

	subscript(_ k: String) -> JSONValue? {
		if case .object(let o) = self { return o[k] }
		return nil
	}
}
