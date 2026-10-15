import AVFoundation
import Foundation
import IPTVCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Recordings and downloads. iOS has no foreground service: while anything records (or a
/// scheduled recording is near), silent background audio keeps the app running, the same way
/// the player keeps playing with the screen locked. Files go to Documents/Recordings, which the
/// Files app shows under "On My iPhone" (tvOS: the cache, the only storage it has).
@MainActor
final class RecorderCenter: ObservableObject {
	/// A recording or download running now. [channelKey] is "" for downloads.
	struct Active: Identifiable {
		let key: String
		let label: String
		let channelKey: String
		let started: Int64
		let end: Int64
		var id: String { key }
	}

	struct Saved: Identifiable {
		let url: URL
		let name: String
		let added: Int64
		var id: URL { url }
	}

	@Published private(set) var active: [String: Active] = [:]
	@Published private(set) var scheduled: [Recording.Scheduled] = []
	weak var library: Library?
	private let prefs: Prefs
	private var tasks: [String: Task<Void, Never>] = [:]
	private var ticker: Timer?
	private let keepAlive = KeepAlive()

	nonisolated static var folder: URL {
		#if os(tvOS)
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		#else
		let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
		#endif
		return base.appendingPathComponent("Recordings", isDirectory: true)
	}

	init(prefs: Prefs) {
		self.prefs = prefs
		scheduled = Self.load()
		// Due schedules start a minute early: streams can be slow to start.
		ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
		tick()
	}

	func isRecording(_ channelKey: String) -> Bool { active[channelKey] != nil }

	// MARK: scheduled list, same JSON as the Android app's

	private static let storeKey = "recordings.list"

	private static func load() -> [Recording.Scheduled] {
		let raw = UserDefaults.standard.string(forKey: storeKey) ?? "[]"
		let all = (try? JSONDecoder().decode([Recording.Scheduled].self, from: Data(raw.utf8))) ?? []
		return all.filter { $0.end > nowMs() }.sorted { $0.start < $1.start }
	}

	private func persist() {
		scheduled = scheduled.filter { $0.end > nowMs() }.sorted { $0.start < $1.start }
		UserDefaults.standard.set(String(decoding: (try? JSONEncoder().encode(scheduled)) ?? Data("[]".utf8), as: UTF8.self), forKey: Self.storeKey)
		updateKeepAlive()
	}

	/// Schedules [start, end] widened by the padding in Settings.
	func schedule(_ ch: Channel, title: String, start: Int64, end: Int64) {
		let s = Recording.padded(id: Int(nowMs() % Int64(Int32.max)), channel: ch, title: title, start: start, end: end,
			preMinutes: prefs.prePadMinutes, postMinutes: prefs.postPadMinutes)
		scheduled.append(s)
		persist()
		Notify.ask()
		// If the app is not running at the start time, this says so instead of silently not recording.
		Notify.at(s.start, id: "sched-\(s.id)", L("record_open_app", s.title.isEmpty ? s.name : s.title))
		tick()
	}

	func cancel(_ id: Int) {
		scheduled.removeAll { $0.id == id }
		persist()
		Notify.cancel("sched-\(id)")
	}

	/// Every 15 s: starts what is due. Writes and publishes only when something changed.
	private func tick() {
		let now = nowMs()
		let due = scheduled.filter { $0.start - 60_000 <= now }
		for s in due {
			scheduled.removeAll { $0.id == s.id }
			Notify.cancel("sched-\(s.id)")
			startScheduled(s)
		}
		if !due.isEmpty || scheduled.contains(where: { $0.end <= now }) { persist() } else { updateKeepAlive() }
	}

	private func startScheduled(_ s: Recording.Scheduled) {
		Task {
			guard let lib = library, let ch = await lib.findChannel(s.channelKey, section: Library.live) else {
				Notify.now(L("recording_failed", s.name))
				return
			}
			start(ch, title: s.title, endMs: s.end)
		}
	}

	// MARK: running

	/// Starts recording now. [endMs] 0 = until stopped.
	func start(_ ch: Channel, title: String, endMs: Int64 = 0) {
		Notify.ask()
		run(key: ch.key, channel: ch, url: ch.url, name: ch.name, title: title, end: endMs, expect: 0)
	}

	/// Saves a catch-up programme, movie or episode to a file.
	func download(_ url: String, name: String, title: String, expectMs: Int64 = 0) {
		Notify.ask()
		run(key: "dl:\(url.hashValue)", channel: nil, url: url, name: name, title: title, end: 0, expect: expectMs)
	}

	/// Stops one recording or download; what was written is kept.
	func stop(_ key: String) { tasks[key]?.cancel() }

	func stopAll() { tasks.values.forEach { $0.cancel() } }

	private func run(key: String, channel: Channel?, url: String, name: String, title: String, end: Int64, expect: Int64) {
		guard tasks[key] == nil else { return }
		let label = [name, title].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " - ")
		active[key] = Active(key: key, label: label, channelKey: channel == nil ? "" : key, started: nowMs(), end: end)
		updateKeepAlive()
		let lib = library
		tasks[key] = Task {
			let msg = await Self.record(lib: lib, channel: channel, url: url, label: label, end: end, expect: expect, live: channel != nil)
			active[key] = nil
			tasks[key] = nil
			updateKeepAlive()
			Notify.now(msg)
		}
	}

	/// Writes the stream to a file; returns the line to show when it is over.
	private nonisolated static func record(lib: Library?, channel: Channel?, url: String, label: String, end: Int64, expect: Int64, live: Bool) async -> String {
		var real = url
		if let ch = channel, ch.needsResolve {
			guard let r = try? await lib?.resolveUrl(ch) else { return L("recording_failed", label) }
			real = r
		}
		let (plain, headers) = M3U.splitHeaders(real)
		let fm = FileManager.default
		try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appendingPathComponent(Recording.fileName(label: label, at: nowMs()))
		var ok = false
		var early = false
		let done = { Task.isCancelled || (end != 0 && nowMs() >= end) }
		// A catch-up download that ends early is fetched again from the start, up to three times.
		for _ in 1...3 {
			let clock = TsClock()
			fm.createFile(atPath: file.path, contents: nil)
			guard let h = try? FileHandle(forWritingTo: file) else { break }
			// Live recordings ride out drops until their end time; a download ends at its end.
			ok = await Recording.copy(open: { try Recording.stream(plain, headers: headers) }, write: { d in
				try h.write(contentsOf: d)
				clock.feed(d)
			}, reconnect: live, done: done)
			try? h.close()
			early = Recording.endedEarly(writtenMs: clock.durationMs, expectMs: expect)
			if !early || done() { break }
			try? await Task.sleep(nanoseconds: 3_000_000_000)
		}
		if !ok { try? fm.removeItem(at: file) }
		return !ok ? L("recording_failed", label) : early ? L("download_ended_early", label) : L("recording_saved", label)
	}

	// MARK: saved files

	func saved() -> [Saved] {
		let keys: [URLResourceKey] = [.creationDateKey]
		let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
		return files.filter { !$0.hasDirectoryPath }.map { u in
			let d = (try? u.resourceValues(forKeys: Set(keys)))?.creationDate ?? Date()
			return Saved(url: u, name: u.lastPathComponent, added: Int64(d.timeIntervalSince1970 * 1000))
		}.sorted { $0.added > $1.added }
	}

	func delete(_ s: Saved) { try? FileManager.default.removeItem(at: s.url) }

	// MARK: staying alive

	/// Silent audio keeps the app running in the background while it records, or when a
	/// scheduled recording starts within six hours (further out, the notification says to
	/// open the app).
	private func updateKeepAlive() {
		let soon = scheduled.contains { $0.start - nowMs() < 6 * 3_600_000 }
		keepAlive.set(!active.isEmpty || soon)
	}
}

/// A looping silent sound: with the audio background mode, the app keeps running while it plays.
final class KeepAlive {
	private var player: AVAudioPlayer?

	func set(_ on: Bool) {
		if on == (player != nil) { return }
		if !on { player?.stop(); player = nil; return }
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
		try? AVAudioSession.sharedInstance().setActive(true)
		player = try? AVAudioPlayer(data: KeepAlive.silence)
		player?.numberOfLoops = -1
		player?.volume = 0
		player?.play()
	}

	/// One second of 8 kHz mono 16-bit silence as a WAV file.
	static let silence: Data = {
		let samples = 8000, bytes = samples * 2
		var d = Data()
		func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
		func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
		d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVEfmt ".utf8))
		u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
		d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
		d.append(Data(count: bytes))
		return d
	}()
}

/// Local notifications for recordings: saved, failed, ended early, and "open the app" for a
/// scheduled start the app could not stay awake for. tvOS shows none.
enum Notify {
	static func ask() {
		#if !os(tvOS)
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
		#endif
	}

	static func now(_ text: String) {
		#if !os(tvOS)
		let c = UNMutableNotificationContent()
		c.title = text
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
		#endif
	}

	static func at(_ ms: Int64, id: String, _ text: String) {
		#if !os(tvOS)
		let seconds = Double(ms - nowMs()) / 1000
		guard seconds > 1 else { return }
		let c = UNMutableNotificationContent()
		c.title = text
		c.sound = .default
		UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
		#endif
	}

	static func cancel(_ id: String) {
		#if !os(tvOS)
		UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
		#endif
	}
}
