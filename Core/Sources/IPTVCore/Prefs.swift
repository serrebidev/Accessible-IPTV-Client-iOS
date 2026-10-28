import Foundation

/// Settings, sources, favourites and remembered audio tracks. Key names and value types match
/// the Android app's prefs, so an Android settings export imports here unchanged.
public final class Prefs {
	public static let defaultBuffer = 25.0
	public static let defaultMaxBuffer = 30.0

	private let d: UserDefaults
	public init(_ defaults: UserDefaults = .standard) { d = defaults }

	private func str(_ k: String, _ def: String = "") -> String { d.string(forKey: k) ?? def }
	private func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
	private func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
	private func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
	private func long(_ k: String) -> Int64 { Int64(truncating: d.object(forKey: k) as? NSNumber ?? 0) }

	public var sources: [Source] {
		get { (try? JSONDecoder().decode([Source].self, from: Data(str("sources", "[]").utf8))) ?? [] }
		set { d.set(String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self), forKey: "sources") }
	}

	public var favorites: Set<String> {
		get { Set(d.stringArray(forKey: "favorites") ?? []) }
		set { d.set(newValue.sorted(), forKey: "favorites") }
	}

	@discardableResult
	public func toggleFavorite(_ key: String) -> Bool {
		let now = !favorites.contains(key)
		if now { favorites.insert(key) } else { favorites.remove(key) }
		return now
	}

	public var preferAudioDescription: Bool { get { bool("preferAd", true) } set { d.set(newValue, forKey: "preferAd") } }
	/// Comma-separated track names or languages, most wanted first.
	public var audioKeywords: String { get { str("audioKeywords") } set { d.set(newValue, forKey: "audioKeywords") } }
	public var useExternalPlayer: Bool { get { bool("externalPlayer", false) } set { d.set(newValue, forKey: "externalPlayer") } }
	/// Desktop's "Show Stream URL": adds the URL to channel details.
	public var showStreamUrl: Bool { get { bool("showStreamUrl", false) } set { d.set(newValue, forKey: "showStreamUrl") } }

	/// Live cushion built during playback; first start needs only half a second.
	/// Historical defaults migrate; other explicit settings are kept.
	public var bufferSeconds: Double {
		get { let v = double("bufferSeconds", Prefs.defaultBuffer); return v == 6 || v == 10 ? Prefs.defaultBuffer : v }
		set { d.set(newValue, forKey: "bufferSeconds") }
	}

	/// Desktop internal_player_max_buffer_seconds: ceiling for the +1 s per stall.
	public var maxBufferSeconds: Double {
		get { let v = double("maxBufferSeconds", Prefs.defaultMaxBuffer); return max(v == 18 ? Prefs.defaultMaxBuffer : v, bufferSeconds) }
		set { d.set(newValue, forKey: "maxBufferSeconds") }
	}

	public var epgDaysAhead: Int { get { int("epgDaysAhead", 2) } set { d.set(newValue, forKey: "epgDaysAhead") } }
	/// Which channel set the guide was built for; see [Library.guideStale].
	public var guideFingerprint: Int { get { int("guideFingerprint", 0) } set { d.set(newValue, forKey: "guideFingerprint") } }
	public var lastUpdateCheck: Int64 { get { long("lastUpdateCheck") } set { d.set(NSNumber(value: newValue), forKey: "lastUpdateCheck") } }
	public var lastEpgImport: Int64 { get { long("lastEpgImport") } set { d.set(NSNumber(value: newValue), forKey: "lastEpgImport") } }
	public var lastGroup: String { get { str("lastGroup") } set { d.set(newValue, forKey: "lastGroup") } }

	/// Minutes a scheduled recording starts early and runs late (desktop: 0 and 2).
	public var prePadMinutes: Int { get { int("prePad", 0) } set { d.set(newValue, forKey: "prePad") } }
	public var postPadMinutes: Int { get { int("postPad", 2) } set { d.set(newValue, forKey: "postPad") } }

	/// Desktop "Automatic Announcements": 0 none, 1 errors only, 2 important events, 3 detailed status.
	public var announceLevel: Int { get { int("announceLevel", 2) } set { d.set(newValue, forKey: "announceLevel") } }
	/// Subtitles are opt-in: nothing is selected, shown or spoken until this is on.
	/// Picking a track or a subtitle file in the player turns them on for that session only.
	public var subtitlesEnabled: Bool { get { bool("subtitlesEnabled", false) } set { d.set(newValue, forKey: "subtitlesEnabled") } }
	/// Subtitle text is spoken as it appears.
	public var speakSubtitles: Bool { get { bool("speakSubtitles", false) } set { d.set(newValue, forKey: "speakSubtitles") } }

	/// Live channels played, newest first; [0] is the one on now, [1] the previous channel.
	public var recent: [String] {
		get { (try? JSONDecoder().decode([String].self, from: Data(str("recent", "[]").utf8))) ?? [] }
		set { d.set(String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self), forKey: "recent") }
	}

	public func addRecent(_ key: String) { recent = Array(([key] + recent.filter { $0 != key }).prefix(20)) }

	private var tracks: [String: String] {
		get { (try? JSONDecoder().decode([String: String].self, from: Data(str("channelTracks", "{}").utf8))) ?? [:] }
		set { d.set(String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), as: UTF8.self), forKey: "channelTracks") }
	}

	/// Track name picked by hand on a channel; comes back ahead of every other rule.
	public func rememberedTrack(_ channelKey: String) -> String? { tracks[channelKey].flatMap { $0.isEmpty ? nil : $0 } }
	public func rememberTrack(_ channelKey: String, _ name: String) { tracks[channelKey] = name }

	/// Every key with its Android type: s string, b boolean, i int, l long, f float, set string set.
	private static let schema: [String: String] = [
		"sources": "s", "favorites": "set", "preferAd": "b", "audioKeywords": "s", "externalPlayer": "b",
		"showStreamUrl": "b", "bufferSeconds": "f", "maxBufferSeconds": "f", "epgDaysAhead": "i",
		"guideFingerprint": "i", "lastUpdateCheck": "l", "lastEpgImport": "l", "lastGroup": "s",
		"prePad": "i", "postPad": "i", "announceLevel": "i", "subtitlesEnabled": "b", "speakSubtitles": "b", "recent": "s", "channelTracks": "s",
	]
	public static let exportApp = "AccessibleIPTV-iOS"
	private static let importable: Set<String> = [exportApp, "AccessibleIPTV-Android"]

	/// Every setting, source and favourite as JSON (Android's typed export format).
	public func export() throws -> Data {
		var settings: [String: Any] = [:]
		for (k, t) in Prefs.schema {
			guard let v = d.object(forKey: k) else { continue }
			switch t {
			case "set": settings[k] = ["set": (v as? [String]) ?? []]
			case "s": settings[k] = ["s": v as? String ?? ""]
			case "b": settings[k] = ["b": (v as? NSNumber)?.boolValue ?? false]
			case "i": settings[k] = ["i": (v as? NSNumber)?.intValue ?? 0]
			case "l": settings[k] = ["l": (v as? NSNumber)?.int64Value ?? 0]
			default: settings[k] = ["f": (v as? NSNumber)?.doubleValue ?? 0]
			}
		}
		return try JSONSerialization.data(withJSONObject: ["app": Prefs.exportApp, "settings": settings], options: [.prettyPrinted, .sortedKeys])
	}

	public struct NotSettings: LocalizedError { public var errorDescription: String? { T("not_settings_file", "Not a settings file") } }

	/// Replaces every setting with an [export], from this app or the Android one.
	public func importSettings(_ data: Data) throws {
		guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let app = o["app"] as? String, Prefs.importable.contains(app),
		      let all = o["settings"] as? [String: Any] else { throw NotSettings() }
		for k in Prefs.schema.keys { d.removeObject(forKey: k) }
		for (k, any) in all {
			guard let v = any as? [String: Any] else { continue }
			if let s = v["s"] as? String { d.set(s, forKey: k) }
			else if let b = v["b"] as? Bool { d.set(b, forKey: k) }
			else if let i = v["i"] as? NSNumber { d.set(i.intValue, forKey: k) }
			else if let l = v["l"] as? NSNumber { d.set(NSNumber(value: l.int64Value), forKey: k) }
			else if let f = v["f"] as? NSNumber { d.set(f.doubleValue, forKey: k) }
			else if let set = v["set"] as? [String] { d.set(set, forKey: k) }
		}
	}
}
