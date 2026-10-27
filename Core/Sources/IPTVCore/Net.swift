import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NetError: LocalizedError {
	case status(Int)
	case badURL(String)
	public var errorDescription: String? {
		switch self {
		case .status(let c): return "Server answered \(c)"
		case .badURL(let u): return "Bad address: \(u)"
		}
	}
}

public enum Net {
	public static var userAgent = "AccessibleIPTV-iOS/0.1"

	// Redirects (http <-> https too) are followed by URLSession itself.
	static let session: URLSession = {
		let c = URLSessionConfiguration.default
		// Some servers (Dispatcharr) take 20 s to send the first byte of a channel.
		c.timeoutIntervalForRequest = 60
		c.requestCachePolicy = .reloadIgnoringLocalCacheData
		c.urlCache = nil
		return URLSession(configuration: c)
	}()

	/// A URL from what a playlist or a person typed: spaces and the like get escaped.
	public static func url(_ s: String) throws -> URL {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if let u = URL(string: t), u.scheme != nil { return u }
		var allowed = CharacterSet.urlQueryAllowed
		allowed.insert(charactersIn: "%#")
		if let e = t.addingPercentEncoding(withAllowedCharacters: allowed), let u = URL(string: e), u.scheme != nil { return u }
		throw NetError.badURL(s)
	}

	public static func request(_ s: String, headers: [String: String] = [:]) throws -> URLRequest {
		var r = URLRequest(url: try url(s))
		r.timeoutInterval = 60
		r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
		return r
	}

	static func check(_ resp: URLResponse?) throws {
		if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { throw NetError.status(h.statusCode) }
	}

	/// Stream hosts worth a warm connection, capped: the first ones seen win.
	public static func warmHosts(_ urls: [String], max: Int = 2) -> [URL] {
		var seen = Set<String>()
		var roots: [URL] = []
		for raw in urls {
			// A playlist entry can carry its headers behind a pipe; they are not part of the address.
			let (plain, _) = M3U.splitHeaders(raw)
			guard let u = URL(string: plain), let scheme = u.scheme?.lowercased(),
			      scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { continue }
			let key = "\(scheme)://\(host):\(u.port ?? (scheme == "https" ? 443 : 80))"
			guard seen.insert(key).inserted else { continue }
			var c = URLComponents()
			c.scheme = scheme
			c.host = host
			c.port = u.port
			c.path = "/"
			if let root = c.url { roots.append(root) }
			if roots.count >= max { break }
		}
		return roots
	}

	/// Warms one idle connection per stream host on the shared session, plus the host's
	/// name in the system resolver, while the user browses: picking a channel then starts
	/// nearer the first byte instead of paying DNS + TCP + TLS up front. Android's player
	/// shares its HTTP client with the app, so there the whole handshake is saved; here
	/// libVLC keeps its own stack, so VLC playback gains the resolved name, and playback
	/// on Apple's stack (AVPlayer) gains the pooled connection too. The request goes to
	/// the host's root — it opens no channel and no provider stream — and its answer is
	/// dropped. The caches (network-caching) are untouched.
	public static func warmUp(_ urls: [String]) {
		for root in warmHosts(urls) {
			var r = URLRequest(url: root)
			r.timeoutInterval = 10
			r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
			session.dataTask(with: r) { _, _, _ in }.resume()
		}
	}

	/// A small body, gzip unwrapped by sniffing the magic bytes.
	public static func data(_ s: String, headers: [String: String] = [:]) async throws -> Data {
		try await response(s, headers: headers).body
	}

	/// A small body and the address it finally came from, after redirects.
	public static func response(_ s: String, headers: [String: String] = [:]) async throws -> (body: Data, url: URL?) {
		let r = try request(s, headers: headers)
		let (d, resp): (Data, URLResponse?) = try await withCheckedThrowingContinuation { cont in
			session.dataTask(with: r) { d, resp, err in
				if let err { cont.resume(throwing: err) } else { cont.resume(returning: (d ?? Data(), resp)) }
			}.resume()
		}
		try check(resp)
		return (try gunzipIfNeeded(d), resp?.url)
	}

	public static func text(_ s: String, headers: [String: String] = [:]) async throws -> String {
		String(decoding: try await data(s, headers: headers), as: UTF8.self)
	}

	/// A big body: downloaded to a temp file (never held in memory), read back in chunks and
	/// deleted afterwards. Gzip is unwrapped as it is read.
	public static func source(_ s: String, headers: [String: String] = [:]) async throws -> ByteSource {
		let r = try request(s, headers: headers)
		let file: URL = try await withCheckedThrowingContinuation { cont in
			session.downloadTask(with: r) { tmp, resp, err in
				if let err { return cont.resume(throwing: err) }
				do {
					try check(resp)
					guard let tmp else { throw NetError.status(0) }
					let dest = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
					try FileManager.default.moveItem(at: tmp, to: dest)
					cont.resume(returning: dest)
				} catch {
					cont.resume(throwing: error)
				}
			}.resume()
		}
		return try sniffGzip(FileSource(file, deleteWhenDone: true))
	}

	/// Streams a JSON array of objects, handing each object's flat fields to [each] as strings.
	/// Xtream VOD lists run past 100 MB; parsing them whole runs a device out of memory.
	/// Nested values are skipped. A non-array body (an error object) yields nothing.
	public static func forEachObject(_ s: String, _ each: ([String: String]) throws -> Void) async throws {
		try JsonStream(try await source(s)).forEachObject(each)
	}
}

/// Minimal pull reader for one job: a top-level array of flat objects.
public final class JsonStream {
	private let src: ByteSource
	private var buf: [UInt8] = []
	private var pos = 0
	private var ended = false

	public init(_ src: ByteSource) { self.src = src }

	struct Broken: LocalizedError { var errorDescription: String? { "Broken JSON" } }

	@inline(__always) private func peek() throws -> UInt8? {
		if pos < buf.count { return buf[pos] }
		if ended { return nil }
		while true {
			guard let d = try src.next() else { ended = true; return nil }
			if d.isEmpty { continue }
			buf = [UInt8](d)
			pos = 0
			return buf[0]
		}
	}

	private func skipSpace() throws {
		while let b = try peek(), b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { pos += 1 }
	}

	private func expect(_ c: UInt8) throws {
		try skipSpace()
		guard try peek() == c else { throw Broken() }
		pos += 1
	}

	public func forEachObject(_ each: ([String: String]) throws -> Void) throws {
		try skipSpace()
		// A UTF-8 byte order mark.
		if try peek() == 0xEF { pos += 3; try skipSpace() }
		guard try peek() == UInt8(ascii: "[") else { return }
		pos += 1
		var fields: [String: String] = [:]
		while true {
			try skipSpace()
			guard let b = try peek() else { throw Broken() }
			if b == UInt8(ascii: "]") { return }
			if b == UInt8(ascii: ",") { pos += 1; continue }
			if b != UInt8(ascii: "{") { try skipValue(); continue }
			pos += 1
			fields.removeAll(keepingCapacity: true)
			while true {
				try skipSpace()
				guard let c = try peek() else { throw Broken() }
				if c == UInt8(ascii: "}") { pos += 1; break }
				if c == UInt8(ascii: ",") { pos += 1; continue }
				let key = try readString()
				try expect(UInt8(ascii: ":"))
				try skipSpace()
				switch try peek() {
				case UInt8(ascii: "\""): fields[key] = try readString()
				case UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "n"): try skipValue()
				default: fields[key] = try readScalar()
				}
			}
			try each(fields)
		}
	}

	private func readScalar() throws -> String {
		var acc: [UInt8] = []
		while let b = try peek(), b != UInt8(ascii: ","), b != UInt8(ascii: "}"), b != UInt8(ascii: "]"), b > 0x20 { acc.append(b); pos += 1 }
		return String(decoding: acc, as: UTF8.self)
	}

	private func readString() throws -> String {
		try skipSpace()
		guard try peek() == UInt8(ascii: "\"") else { throw Broken() }
		pos += 1
		var acc: [UInt8] = []
		var pendingHigh: UInt32?
		while true {
			guard try peek() != nil else { throw Broken() }
			// Plain run up to the next quote or backslash, copied in one go.
			let start = pos
			let stop = buf.withUnsafeBufferPointer { p -> Int in
				var i = start
				while i < p.count && p[i] != 0x22 && p[i] != 0x5C { i += 1 }
				return i
			}
			if stop > start { acc.append(contentsOf: buf[start..<stop]); pos = stop; continue }
			let b = buf[pos]
			pos += 1
			if b == UInt8(ascii: "\"") { break }
			if b != UInt8(ascii: "\\") { acc.append(b); continue }
			guard let e = try peek() else { throw Broken() }
			pos += 1
			switch e {
			case UInt8(ascii: "n"): acc.append(0x0A)
			case UInt8(ascii: "t"): acc.append(0x09)
			case UInt8(ascii: "r"): acc.append(0x0D)
			case UInt8(ascii: "b"): acc.append(0x08)
			case UInt8(ascii: "f"): acc.append(0x0C)
			case UInt8(ascii: "u"):
				var hex: [UInt8] = []
				for _ in 0..<4 { guard let h = try peek() else { throw Broken() }; hex.append(h); pos += 1 }
				guard let v = UInt32(String(decoding: hex, as: UTF8.self), radix: 16) else { throw Broken() }
				if (0xD800...0xDBFF).contains(v) { pendingHigh = v; continue }
				var scalar = v
				if (0xDC00...0xDFFF).contains(v), let hi = pendingHigh { scalar = 0x10000 + ((hi - 0xD800) << 10) + (v - 0xDC00) }
				pendingHigh = nil
				if let u = UnicodeScalar(scalar) { acc.append(contentsOf: Array(String(Character(u)).utf8)) }
			default: acc.append(e) // \" \\ \/
			}
		}
		return String(decoding: acc, as: UTF8.self)
	}

	private func skipValue() throws {
		try skipSpace()
		guard let b = try peek() else { throw Broken() }
		if b == UInt8(ascii: "\"") { _ = try readString(); return }
		if b != UInt8(ascii: "{") && b != UInt8(ascii: "[") { _ = try readScalar(); return }
		var depth = 0
		while let c = try peek() {
			if c == UInt8(ascii: "\"") { _ = try readString(); continue }
			pos += 1
			if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
			if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return } }
		}
		throw Broken()
	}
}
