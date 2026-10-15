#if canImport(SQLite3)
import Foundation

/// Process-wide state: the three sections (live, movies, series) and one guide.
/// Port of the Android App class, minus the Android parts.
public final class Library {
	public static let live = "live"
	public static let movies = "movies"
	public static let series = "series"
	public static let sections = [live, movies, series]
	public static let all = "All"
	public static let favorites = "Favorites"
	public static func xtreamBehind(_ src: Source) -> Source? { Lists.xtreamBehind(src) }
	public static func searchRanked(_ list: [Channel], _ q: String) -> [Channel] { Lists.searchRanked(list, q) }

	/// Search across one section, using the names prepared at load time.
	public func search(_ section: String, _ q: String) -> [Channel] {
		lock.lock(); let items = lists[section] ?? []; let lower = lowerNames[section] ?? []; lock.unlock()
		return lower.count == items.count ? Lists.ranked(items, lower, q) : Lists.searchRanked(items, q)
	}

	public let prefs: Prefs
	public let epg: Epg
	private let dir: URL
	private let lock = NSLock()
	private var lists: [String: [Channel]] = [:]
	/// Search form of every name, built once per load (see Lists.lowerName).
	private var lowerNames: [String: [String]] = [:]
	/// Match keys of the live list, hashed once per load so [guideStale] stays off the main thread.
	private var fingerprintCache: Int?
	/// When the last guide import failed this run: a failing guide is not retried on every load.
	private var lastGuideFailure: Int64 = 0
	private var stalkers: [String: Stalker] = [:]

	/// Reads a picked M3U file; the app resolves its security-scoped bookmark.
	public var readFile: (String) throws -> String = { _ in throw NetError.badURL("file") }
	/// Opens one guide URL; tests swap in local data.
	public var openGuide: (String) async throws -> ByteSource = { try await Net.source($0) }

	/// Opens the guide database but does not read its channel index: this runs before the app's
	/// first frame, and a national guide's index is tens of thousands of rows. [load] reads it on
	/// the thread doing the load, and [Epg.importGuide] after an import.
	public init(dir: URL, prefs: Prefs) throws {
		self.dir = dir
		self.prefs = prefs
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		epg = try Epg(path: dir.appendingPathComponent("epg.db").path)
	}

	/// Live channels: what the guide, recordings and catch-up work with.
	public var channels: [Channel] { list(Library.live) }

	public func list(_ section: String) -> [Channel] { lock.lock(); defer { lock.unlock() }; return lists[section] ?? [] }
	public func isLoaded(_ section: String) -> Bool { lock.lock(); defer { lock.unlock() }; return lists[section] != nil }

	private func cacheFile(_ src: Source, _ section: String) -> URL { dir.appendingPathComponent("channels_\(src.id)_\(section).json") }

	/// Loads one section from cache, downloading sources with no cache, or all when [force].
	/// Returns one line per source that failed.
	public func load(_ section: String, force: Bool) async -> [String] {
		var errors: [String] = []
		var all: [Channel] = []
		for src in prefs.sources {
			let cache = cacheFile(src, section)
			do {
				// Providers add and drop channels: a cache older than 12 hours is fetched again.
				let mtime = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date
				let fresh = mtime.map { Date().timeIntervalSince($0) < 12 * 3600 } ?? false
				all += !force && fresh ? try readCache(cache) : try await fetch(src, section)
			} catch {
				errors.append("\(src.name): \(error.localizedDescription)")
				all += (try? readCache(cache)) ?? []
			}
		}
		let lower = all.map { Lists.lowerName($0.name) }
		// Hashing every live channel is a second of work on a phone: only when the guide could need
		// it, and here, on the thread doing the load rather than on the main thread at every check.
		let fp = section == Library.live && guideRecent ? Self.fingerprint(all) : nil
		lock.lock(); lists[section] = all; lowerNames[section] = lower
		if section == Library.live { fingerprintCache = fp }
		lock.unlock()
		if section == Library.live && !epg.hasGuide { epg.loadIndex() }
		return errors
	}

	/// Downloads [section] of [src] and caches it. An M3U fills all three caches at once.
	private func fetch(_ src: Source, _ section: String) async throws -> [Channel] {
		if src.isXtream {
			let list: [Channel]
			switch section {
			case Library.movies: list = try await Xtream.movies(src)
			case Library.series: list = try await Xtream.series(src)
			default: list = try await Xtream.liveChannels(src)
			}
			try writeCache(cacheFile(src, section), list)
			return list
		}
		if src.isStalker {
			let list = section == Library.live ? try await stalker(src).channels() : []
			try writeCache(cacheFile(src, section), list)
			return list
		}
		let text = try await readSource(src)
		let parsed = M3U.parse(sourceId: src.id, text: text)
		var bySection: [String: [Channel]] = [:]
		for c in parsed {
			let s = c.kind == Channel.kindLive ? Library.live : c.kind == Channel.kindMovie ? Library.movies : Library.series
			bySection[s, default: []].append(c)
		}
		keepFavorites(cacheFile(src, Library.live), bySection[Library.live] ?? [])
		for s in Library.sections { try writeCache(cacheFile(src, s), bySection[s] ?? []) }
		// A playlist that names its own guide (x-tvg-url) needs no guide URL typed in.
		if src.epgUrl.trimmingCharacters(in: .whitespaces).isEmpty, let g = M3U.headerGuides(text).first {
			prefs.sources = prefs.sources.map { var s = $0; if s.id == src.id { s.epgUrl = g }; return s }
		}
		return bySection[section] ?? []
	}

	/// Channel ids changed (0.2.5 and older Android used list position for M3U). Favourites
	/// follow their channel by stream URL, so nobody has to mark them again.
	private func keepFavorites(_ oldCache: URL, _ fresh: [Channel]) {
		let favs = prefs.favorites
		guard !favs.isEmpty, let old = try? readCache(oldCache) else { return }
		var byUrl: [String: Channel] = [:]
		for c in fresh where byUrl[c.url] == nil { byUrl[c.url] = c }
		var moved: [String: String] = [:]
		for o in old where favs.contains(o.key) { if let n = byUrl[o.url] { moved[o.key] = n.key } }
		if moved.contains(where: { $0.key != $0.value }) { prefs.favorites = Set(favs.map { moved[$0] ?? $0 }) }
	}

	/// Playlist text from a URL or from a file the user picked.
	private func readSource(_ src: Source) async throws -> String {
		src.isFile ? try readFile(src.url) : try await Net.text(src.url)
	}

	public func forgetCache(_ src: Source) {
		for s in Library.sections { try? FileManager.default.removeItem(at: cacheFile(src, s)) }
	}

	private func readCache(_ f: URL) throws -> [Channel] { try JSONDecoder().decode([Channel].self, from: Data(contentsOf: f)) }

	// ponytail: one JSON file per section; 250k movies is ~50 MB. Move to SQLite if memory bites.
	private func writeCache(_ f: URL, _ list: [Channel]) throws { try JSONEncoder().encode(list).write(to: f, options: .atomic) }

	/// Group names in playlist order, with "Favorites" and "All" on top like the desktop app, each
	/// with its number of entries. One pass for both, because the main screen shows the count beside
	/// every group on a list of up to 250,000 entries; the caller runs it off the main thread.
	public func groupSummary(_ section: String) -> [(name: String, count: Int)] {
		let f = prefs.favorites
		var counts: [String: Int] = [:]
		var order: [String] = []
		var favourites = 0
		var total = 0
		for c in list(section) {
			if let n = counts[c.group] { counts[c.group] = n + 1 } else { counts[c.group] = 1; order.append(c.group) }
			total += 1
			if f.contains(c.key) { favourites += 1 }
		}
		return [(Library.all, total), (Library.favorites, favourites)] + order.map { ($0, counts[$0] ?? 0) }
	}

	public func channelsIn(_ section: String, _ group: String) -> [Channel] {
		switch group {
		case Library.all: return list(section)
		case Library.favorites: let f = prefs.favorites; return list(section).filter { f.contains($0.key) }
		default: return list(section).filter { $0.group == group }
		}
	}

	public func channel(_ key: String) -> Channel? {
		lock.lock(); let all = lists; lock.unlock()
		for s in Library.sections { if let c = all[s]?.first(where: { $0.key == key }) { return c } }
		for l in all.values { if let c = l.first(where: { $0.key == key }) { return c } }
		return nil
	}

	/// [channel], loading [section] from its cache first when the process is new.
	public func findChannel(_ key: String, section: String) async -> Channel? {
		if let c = channel(key) { return c }
		if !isLoaded(section) { _ = await load(section, force: false) }
		return channel(key)
	}

	public func source(_ id: String) -> Source? { prefs.sources.first { $0.id == id } }

	private func stalker(_ src: Source) -> Stalker {
		lock.lock(); defer { lock.unlock() }
		if let s = stalkers[src.id] { return s }
		let s = Stalker(src)
		stalkers[src.id] = s
		return s
	}

	public struct PlaylistRemoved: LocalizedError { public var errorDescription: String? { T("playlist_removed", "Playlist removed") } }

	/// The URL to play or record. Stalker portals issue a fresh link each time.
	public func resolveUrl(_ ch: Channel) async throws -> String {
		if !ch.needsResolve { return ch.url }
		guard let src = source(ch.sourceId) else { throw PlaylistRemoved() }
		return try await stalker(src).link(String(ch.url.dropFirst(Channel.stalkerScheme.count)))
	}

	/// Archive URL for a past programme, or nil when there is none.
	public func catchupUrl(_ ch: Channel, start: Int64, stop: Int64) async -> String? {
		guard ch.hasCatchup, Catchup.withinWindow(ch, start) else { return nil }
		if ch.needsResolve {
			guard let src = source(ch.sourceId) else { return nil }
			let w = Catchup.wall(start, .current)
			let token = String(format: "%04d-%02d-%02d:%02d-%02d", w.year, w.month, w.day, w.hour, w.minute)
			return try? await stalker(src).link(String(ch.url.dropFirst(Channel.stalkerScheme.count)), startToken: token, minutes: max(1, (stop - start) / 60_000))
		}
		return Catchup.url(ch, start, stop)
	}

	public func episodes(_ show: Channel) async throws -> [Channel] {
		guard let src = source(show.sourceId) else { return [] }
		return try await Xtream.episodes(src, show: show)
	}

	public func accountInfo(_ src: Source) async throws -> [(String, String)] {
		if src.isStalker { return try await stalker(src).accountInfo() }
		if src.isXtream { return try await Xtream.accountInfo(src) }
		if let x = Lists.xtreamBehind(src) { return try await Xtream.accountInfo(x) }
		return []
	}

	/// Downloads every playlist's guide into the guide database.
	public func importGuide(progress: @escaping (Int) -> Void = { _ in }) async throws -> Int {
		var urls: [String] = []
		for s in prefs.sources { let u = s.effectiveEpgUrl; if !u.trimmingCharacters(in: .whitespaces).isEmpty && !urls.contains(u) { urls.append(u) } }
		let now = nowMs()
		let back = Int64(min(7, max(1, channels.map(\.catchupDays).max() ?? 0)))
		let n: Int
		do {
			n = try await epg.importGuide(urls.map { u in { [openGuide] in try await openGuide(u) } }, channels: channels,
				fromMs: now - back * 86_400_000, toMs: now + Int64(prefs.epgDaysAhead) * 86_400_000, progress: progress)
		} catch {
			lastGuideFailure = nowMs()
			throw error
		}
		lastGuideFailure = 0
		prefs.lastEpgImport = now
		prefs.guideFingerprint = guideFingerprint()
		return n
	}

	/// The import keeps only guide channels the playlist can match, so a playlist that gained
	/// channels since the last import has channels with no guide at all. The fingerprint is
	/// the set of match keys (FNV-1a, stable across launches); any change means re-import now.
	func guideFingerprint() -> Int {
		lock.lock(); let cached = fingerprintCache; lock.unlock()
		if let cached { return cached }
		// After an import the list has not been hashed yet (the guide was stale when it loaded):
		// keep what we computed so the next staleness check, on the main thread, does not redo it.
		let fp = Self.fingerprint(channels)
		lock.lock(); fingerprintCache = fp; lock.unlock()
		return fp
	}

	/// The match keys of [list]; the same hash the load stores, for the paths that have no cache.
	private static func fingerprint(_ list: [Channel]) -> Int {
		let keys = Set(list.map { $0.tvgId.isEmpty ? Xmltv.nameKey($0.name) : $0.tvgId.lowercased() }).sorted()
		var h: UInt32 = 2_166_136_261
		for k in keys { for b in k.utf8 + [10] { h = (h ^ UInt32(b)) &* 16_777_619 } }
		return Int(Int32(bitPattern: h))
	}

	/// A guide imported within the last day: the only time the channel list is hashed to compare it.
	private var guideRecent: Bool { prefs.lastEpgImport != 0 && nowMs() - prefs.lastEpgImport <= 86_400_000 }

	/// Never imported, a day old, or built for another channel list. A guide that matched no
	/// channel counts as imported (it used to be fetched again on every load), and a failed
	/// import waits an hour before the next automatic try.
	public func guideStale() -> Bool {
		if channels.isEmpty || nowMs() - lastGuideFailure < 3_600_000 { return false }
		return !guideRecent || guideFingerprint() != prefs.guideFingerprint
	}
}
#endif
