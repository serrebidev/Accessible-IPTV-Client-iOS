import Foundation

/// Stalker / Ministra portal client: the MAG-style handshake, ported from the desktop app.
public actor Stalker {
	private let src: Source
	private var token = ""
	private var issued: Int64 = 0
	private let endpoint: String
	private let base: String

	public init(_ src: Source) {
		self.src = src
		let u = src.url.trimmingCharacters(in: .whitespaces)
		endpoint = u.hasSuffixCI("portal.php") || u.hasSuffixCI("load.php") ? u : Stalker.baseUrl(u) + "/portal.php"
		base = Stalker.baseUrl(src.url)
	}

	struct PortalError: LocalizedError {
		let errorDescription: String?
		init(_ m: String) { errorDescription = m }
	}

	private func call(_ params: [String: String], withToken: Bool = true) async throws -> JSONValue {
		var p = params
		p["JsHttpRequest"] = "1-xml"
		let q = p.keys.sorted().map { "\($0)=\(Source.enc(p[$0]!))" }.joined(separator: "&")
		var h = [
			"User-Agent": "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/535.21 (KHTML, like Gecko) MAG250 stbapp Safari/535.21",
			"X-User-Agent": "Model: MAG420; Link: WiFi",
			"Referer": "\(base)/c/",
			"Cookie": "stb_lang=en; timezone=UTC; mac=\(src.mac)",
		]
		if withToken && !token.isEmpty { h["Authorization"] = "Bearer \(token)" }
		let body = try await Net.data("\(endpoint)?\(q)", headers: h)
		return try JSONDecoder().decode(JSONValue.self, from: body)
	}

	private func ensureToken() async throws {
		if !token.isEmpty && nowMs() - issued < 25 * 60_000 { return }
		let hs = try await call(["type": "stb", "action": "handshake", "token": "", "prehash": "0"], withToken: false)
		token = hs["js"]?["token"]?.text ?? ""
		if token.isEmpty { token = hs["token"]?.text ?? "" }
		if token.isEmpty { throw PortalError("Portal handshake failed") }
		issued = nowMs()
		// Many portals authenticate by MAC alone; log in only when credentials were given.
		if !src.username.isEmpty || !src.password.isEmpty {
			let auth = try await call(["type": "stb", "action": "login", "login": src.username, "password": src.password])
			if let t = auth["js"]?["token"]?.text, !t.isEmpty { token = t }
		}
	}

	public func channels() async throws -> [Channel] {
		try await ensureToken()
		var genres: [String: String] = [:]
		if case .array(let g)? = (try? await call(["type": "itv", "action": "get_genres"]))?["js"] {
			for item in g { genres[item["id"]?.text ?? ""] = item["title"]?.text ?? "" }
		}
		guard case .array(let data)? = try await call(["type": "itv", "action": "get_all_channels", "force_ch_link_check": "1"])["js"]?["data"] else { return [] }
		var out: [Channel] = []
		for r in data {
			func f(_ k: String) -> String { r[k]?.text ?? "" }
			let name = f("name"), cmd = f("cmd")
			if name.isEmpty || cmd.isEmpty { continue }
			var attrs: [String: String] = [:]
			if f("allow_timeshift") == "1" || f("archive") == "1" {
				attrs["catchup"] = "stalker"
				attrs["catchup-days"] = f("tv_archive_duration").isEmpty ? "0" : f("tv_archive_duration")
			}
			let num = f("number")
			if !num.trimmingCharacters(in: .whitespaces).isEmpty && num != "null" { attrs[Channel.chno] = num }
			let genre = f("tv_genre_title")
			out.append(Channel(
				sourceId: src.id,
				itemId: f("id").isEmpty ? String(out.count) : f("id"),
				name: name,
				group: genres[f("tv_genre_id")] ?? (genre.isEmpty ? "Stalker" : genre),
				url: Channel.stalkerScheme + cmd,
				tvgId: f("xmltv_id").isEmpty ? f("epg_id") : f("xmltv_id"),
				logo: f("logo"),
				attrs: attrs
			))
		}
		return out
	}

	/// A playable link for a channel's cmd; [startToken]/[minutes] ask for catch-up.
	public func link(_ cmd: String, startToken: String? = nil, minutes: Int64 = 0) async throws -> String {
		try await ensureToken()
		var p = ["type": "itv", "action": "create_link", "cmd": cmd]
		if let s = startToken {
			for (k, v) in ["download": "0", "save": "0", "series": "1", "forced_storage": "0", "start": s, "duration": String(minutes)] { p[k] = v }
		}
		let res = try await call(p)
		var link = res["js"]?["cmd"]?.text ?? ""
		if link.isEmpty { link = res["cmd"]?.text ?? "" }
		if link.isEmpty { throw PortalError("Portal did not return a stream link") }
		for prefix in ["ffmpeg ", "auto "] where link.hasPrefix(prefix) { link = String(link.dropFirst(prefix.count)) }
		return link.trimmingCharacters(in: .whitespaces)
	}

	public func accountInfo() async throws -> [(String, String)] {
		try await ensureToken()
		guard let js = try await call(["type": "account_info", "action": "get_main_info"])["js"] else { return [] }
		let labels = [("tariff_plan", T("account_plan", "Plan")), ("end_date", T("account_expires", "Expires")), ("phone", T("account_expires", "Expires")),
		              ("account_balance", T("account_balance", "Balance")), ("fname", T("account_name", "Name"))]
		var out: [(String, String)] = []
		for (k, label) in labels {
			let v = js[k]?.text ?? ""
			if !v.trimmingCharacters(in: .whitespaces).isEmpty && v != "null" && !out.contains(where: { $0.0 == label }) { out.append((label, v)) }
		}
		return out
	}

	/// Portal base without a trailing /c, /portal.php or /server/load.php.
	public nonisolated static func baseUrl(_ url: String) -> String {
		var u = Xtream.withScheme(url)
		for tail in ["/portal.php", "/server/load.php", "/load.php", "/c"] where u.hasSuffixCI(tail) { u = String(u.dropLast(tail.count)) }
		return u.trimmingSuffix("/")
	}
}
