#if canImport(SQLite3)
import Foundation
import SQLite3

/// Guide storage. Programmes are keyed by the XMLTV channel id; a channel finds its guide by
/// tvg-id first, then by a normalised name. WAL with a separate reader connection: channel
/// rows read now/next on the main thread while an import writes for minutes.
public final class Epg {
	private var writer: OpaquePointer?
	private var reader: OpaquePointer?
	private let readLock = NSLock()
	private let importLock = NSLock()
	private var importing = false
	private let indexLock = NSLock()
	private var byId: [String: String] = [:]
	private var byName: [String: String] = [:]

	public struct DBError: LocalizedError {
		public let errorDescription: String?
	}

	public init(path: String) throws {
		writer = try Epg.open(path)
		try exec(writer, "PRAGMA journal_mode=WAL")
		try exec(writer, "CREATE TABLE IF NOT EXISTS prog (ch TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, title TEXT, descr TEXT)")
		try exec(writer, "CREATE INDEX IF NOT EXISTS prog_ch ON prog (ch, start)")
		try exec(writer, "CREATE INDEX IF NOT EXISTS prog_time ON prog (start, stop)")
		try exec(writer, "CREATE TABLE IF NOT EXISTS gch (id TEXT PRIMARY KEY, namekey TEXT)")
		reader = try Epg.open(path)
	}

	deinit {
		sqlite3_close(writer)
		sqlite3_close(reader)
	}

	private static func open(_ path: String) throws -> OpaquePointer? {
		var db: OpaquePointer?
		guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
			let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
			sqlite3_close(db)
			throw DBError(errorDescription: msg)
		}
		sqlite3_busy_timeout(db, 10_000)
		return db
	}

	private func exec(_ db: OpaquePointer?, _ sql: String) throws {
		if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw DBError(errorDescription: String(cString: sqlite3_errmsg(db))) }
	}

	private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

	/// Rows of [sql] on the reader connection; [row] reads columns from the statement.
	private func query<T>(_ sql: String, _ args: [Any], _ row: (OpaquePointer) -> T) -> [T] {
		readLock.lock(); defer { readLock.unlock() }
		var st: OpaquePointer?
		guard sqlite3_prepare_v2(reader, sql, -1, &st, nil) == SQLITE_OK, let s = st else { return [] }
		defer { sqlite3_finalize(s) }
		for (i, a) in args.enumerated() {
			if let v = a as? Int64 { sqlite3_bind_int64(s, Int32(i + 1), v) } else { sqlite3_bind_text(s, Int32(i + 1), "\(a)", -1, Epg.transient) }
		}
		var out: [T] = []
		while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
		return out
	}

	private static func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }

	/// Reloads the channel lookup tables; call after an import or on start.
	public func loadIndex() {
		var ids: [String: String] = [:]
		var names: [String: String] = [:]
		for (id, key) in query("SELECT id, namekey FROM gch", [], { (Epg.text($0, 0), Epg.text($0, 1)) }) {
			ids[id.lowercased()] = id
			if !key.isEmpty && names[key] == nil { names[key] = id }
		}
		indexLock.lock(); byId = ids; byName = names; indexLock.unlock()
	}

	public func guideId(_ ch: Channel) -> String? {
		indexLock.lock(); defer { indexLock.unlock() }
		if !ch.tvgId.isEmpty, let id = byId[ch.tvgId.lowercased()] { return id }
		return byName[Xmltv.nameKey(ch.name)]
	}

	public var hasGuide: Bool { indexLock.lock(); defer { indexLock.unlock() }; return !byId.isEmpty }

	public struct NowNext {
		public let now: Programme?
		public let next: Programme?
		public var isEmpty: Bool { now == nil && next == nil }
	}

	private func programmes(_ sql: String, _ args: [Any], _ ch: Channel) -> [Programme] {
		query(sql, args) { s in
			Programme(channelKey: ch.key, start: sqlite3_column_int64(s, 0), stop: sqlite3_column_int64(s, 1),
				title: Epg.text(s, 2), description: Epg.text(s, 3), channelName: ch.name)
		}
	}

	/// The programme on now and the one after it. In a gap there is no "now", only a next.
	public func nowNext(_ ch: Channel, now: Int64 = nowMs()) -> NowNext {
		guard let id = guideId(ch) else { return NowNext(now: nil, next: nil) }
		let two = programmes("SELECT start, stop, title, descr FROM prog WHERE ch=? AND stop>? ORDER BY start LIMIT 2", [id, now], ch)
		if let first = two.first, first.start <= now { return NowNext(now: first, next: two.count > 1 ? two[1] : nil) }
		return NowNext(now: nil, next: two.first)
	}

	public func schedule(_ ch: Channel, from: Int64, to: Int64) -> [Programme] {
		guard let id = guideId(ch) else { return [] }
		return programmes("SELECT start, stop, title, descr FROM prog WHERE ch=? AND stop>? AND start<? ORDER BY start", [id, from, to], ch)
	}

	private func byGuide(_ channels: [Channel]) -> [String: Channel] {
		var out: [String: Channel] = [:]
		for c in channels { if let id = guideId(c), out[id] == nil { out[id] = c } }
		return out
	}

	/// Everything airing now, paired with the first playlist channel that uses each guide.
	public func onNow(_ channels: [Channel], now: Int64 = nowMs()) -> [(Programme, Channel)] {
		let map = byGuide(channels)
		let rows = query("SELECT ch, start, stop, title, descr FROM prog WHERE start<=? AND stop>?", [now, now]) { s in
			(Epg.text(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2), Epg.text(s, 3), Epg.text(s, 4))
		}
		var out: [(Programme, Channel)] = []
		for r in rows {
			guard let ch = map[r.0] else { continue }
			out.append((Programme(channelKey: ch.key, start: r.1, stop: r.2, title: r.3, description: r.4, channelName: ch.name), ch))
		}
		return out.sorted { $0.0.title.lowercased() < $1.0.title.lowercased() }
	}

	/// Guide search: programmes not yet over whose title or description holds [q].
	public func search(_ q: String, _ channels: [Channel], now: Int64 = nowMs()) -> [(Programme, Channel)] {
		let map = byGuide(channels)
		let like = "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
		let rows = query("SELECT ch, start, stop, title, descr FROM prog WHERE stop>? AND (title LIKE ? ESCAPE '\\' OR descr LIKE ? ESCAPE '\\') ORDER BY start LIMIT 500", [now, like, like]) { s in
			(Epg.text(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_int64(s, 2), Epg.text(s, 3), Epg.text(s, 4))
		}
		var out: [(Programme, Channel)] = []
		for r in rows {
			guard let ch = map[r.0] else { continue }
			out.append((Programme(channelKey: ch.key, start: r.1, stop: r.2, title: r.3, description: r.4, channelName: ch.name), ch))
		}
		return out
	}

	/// Advances [p]; true at </[tag]>. A file cut off mid-element throws instead of spinning at the end.
	private func endOf(_ p: XmlPull, _ tag: String) throws -> Bool {
		switch try p.next() {
		case .end: return p.name == tag
		case .eof: throw ByteError.endedEarly
		default: return false
		}
	}

	/// Replaces the guide with [sources] (one per guide URL). Only guide channels some playlist
	/// channel can match are kept, inside [fromMs, toMs]: a 150 MB national guide stays small.
	/// The new guide is built beside the old one and swapped in only when every source was
	/// read: a dropped download never leaves half a guide or none.
	public func importGuide(_ sources: [() async throws -> ByteSource], channels: [Channel], fromMs: Int64, toMs: Int64, progress: (Int) -> Void = { _ in }) async throws -> Int {
		// One import at a time. A flag, not a held lock: awaits may resume on another thread.
		importLock.lock()
		let busy = importing
		importing = true
		importLock.unlock()
		if busy { throw DBError(errorDescription: "Guide import already running") }
		defer { importLock.lock(); importing = false; importLock.unlock() }
		let wantIds = Set(channels.compactMap { $0.tvgId.isEmpty ? nil : $0.tvgId.lowercased() })
		let wantNames = Set(channels.map { Xmltv.nameKey($0.name) })
		let db = writer
		try exec(db, "PRAGMA cache_size=-4000")
		try exec(db, "DROP TABLE IF EXISTS prog_new")
		try exec(db, "DROP TABLE IF EXISTS gch_new")
		try exec(db, "CREATE TABLE prog_new (ch TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, title TEXT, descr TEXT)")
		try exec(db, "CREATE TABLE gch_new (id TEXT PRIMARY KEY, namekey TEXT)")
		var insProg: OpaquePointer?, insCh: OpaquePointer?
		sqlite3_prepare_v2(db, "INSERT INTO prog_new (ch, start, stop, title, descr) VALUES (?,?,?,?,?)", -1, &insProg, nil)
		sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO gch_new (id, namekey) VALUES (?,?)", -1, &insCh, nil)
		defer { sqlite3_finalize(insProg); sqlite3_finalize(insCh) }
		// A channel id two guides both carry is taken from the first only; otherwise every
		// programme appears twice and "Now" and "Next" read the same show.
		var taken = Set<String>()
		var count = 0
		do {
			try exec(db, "BEGIN")
			for open in sources {
				var kept = Set<String>()
				let p = XmlPull(try await open())
				var ev = try p.next()
				while ev != .eof {
					if ev == .start && p.name == "channel" {
						let id = p.attrs["id"] ?? ""
						var names: [String] = []
						while try !endOf(p, "channel") {
							if p.event == .start && p.name == "display-name" { names.append(Xmltv.nameKey(try p.nextText())) }
						}
						let match = wantIds.contains(id.lowercased()) || names.contains(where: wantNames.contains)
						if !id.isEmpty && match && !taken.contains(id) {
							kept.insert(id)
							sqlite3_reset(insCh)
							sqlite3_bind_text(insCh, 1, id, -1, Epg.transient)
							sqlite3_bind_text(insCh, 2, names.first(where: wantNames.contains) ?? names.first ?? "", -1, Epg.transient)
							sqlite3_step(insCh)
						}
					} else if ev == .start && p.name == "programme" {
						let id = p.attrs["channel"] ?? ""
						// Skip unmatched channels before doing any work on their times.
						let start = kept.contains(id) ? Xmltv.parseTime(p.attrs["start"]) : nil
						let stop = start != nil ? Xmltv.parseTime(p.attrs["stop"]) : nil
						if let start, let stop, stop > fromMs, start < toMs {
							var title = "", desc = ""
							while try !endOf(p, "programme") {
								if p.event == .start {
									if p.name == "title" { let t = try p.nextText(); if title.isEmpty { title = t } }
									else if p.name == "desc" { let t = try p.nextText(); if desc.isEmpty { desc = t } }
								}
							}
							sqlite3_reset(insProg)
							sqlite3_bind_text(insProg, 1, id, -1, Epg.transient)
							sqlite3_bind_int64(insProg, 2, start)
							sqlite3_bind_int64(insProg, 3, stop)
							sqlite3_bind_text(insProg, 4, title, -1, Epg.transient)
							sqlite3_bind_text(insProg, 5, desc, -1, Epg.transient)
							sqlite3_step(insProg)
							count += 1
							if count % 20_000 == 0 {
								// Small transactions keep memory low on a 2 GB Apple TV.
								try exec(db, "COMMIT")
								try exec(db, "BEGIN")
								progress(count)
							}
						}
					}
					ev = try p.next()
				}
				taken.formUnion(kept)
			}
			try exec(db, "COMMIT")
		} catch {
			_ = try? exec(db, "ROLLBACK")
			_ = try? exec(db, "DROP TABLE IF EXISTS prog_new")
			_ = try? exec(db, "DROP TABLE IF EXISTS gch_new")
			throw error
		}
		try exec(db, "BEGIN")
		do {
			try exec(db, "DROP TABLE prog")
			try exec(db, "DROP TABLE gch")
			try exec(db, "ALTER TABLE prog_new RENAME TO prog")
			try exec(db, "ALTER TABLE gch_new RENAME TO gch")
			// Indexes after the bulk insert: faster than keeping them up to date row by row.
			try exec(db, "CREATE INDEX prog_ch ON prog (ch, start)")
			try exec(db, "CREATE INDEX prog_time ON prog (start, stop)")
			try exec(db, "COMMIT")
		} catch {
			_ = try? exec(db, "ROLLBACK")
			throw error
		}
		loadIndex()
		return count
	}
}
#endif
