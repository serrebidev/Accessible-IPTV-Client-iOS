import Foundation
import SwiftUI
import IPTVCore
#if canImport(UIKit)
import UIKit
#endif

/// Localized string from Localizable.strings (converted from the Android app's 14 languages).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }
/// Plural string from Localizable.stringsdict.
func P(_ key: String, _ n: Int) -> String { String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), n) }

/// Speaks [text] with VoiceOver (polite: queued behind what is being read).
func announce(_ text: String) {
	guard !text.isEmpty else { return }
	AccessibilityNotification.Announcement(text).post()
}

/// TEMPORARY, 0.1.8: what a slow list change costs, said out loud in the status line so it can be
/// measured on a device (the category switch was reported as 5 seconds and does not reproduce on
/// the machine it is built on). Counts the rows the list builds and the redraws the screen does
/// between the tap and the list settling. Silent unless the change took over a second, and goes
/// away once the cost is known.
@MainActor
enum SwitchTiming {
	private static var began: Int64 = 0
	private static var lastRow: Int64 = 0
	private static var beforeMs: Int64 = 0
	private static var label = ""
	private static var rows = 0
	private static var bodies = 0

	static func begin(_ what: String) {
		began = nowMs(); lastRow = began; beforeMs = 0; label = what
		rows = 0; bodies = 0
	}

	/// A row the list built, and a redraw of the main screen.
	static func row() {
		rows += 1
		lastRow = nowMs()
	}
	static func body() { bodies += 1 }
	/// What the work before the list was shown cost: the filter, the load.
	static func before(_ ms: Int64) { beforeMs = ms }

	/// Says what it cost, but only when the list itself was slow.
	static func report() {
		guard began > 0 else { return }
		let showed = lastRow - began - beforeMs
		let total = nowMs() - began
		began = 0
		guard showed > 1_000 else { return }
		AppModel.shared.setStatus("SLOW \(label): filter \(beforeMs) ms, \(rows) rows in \(showed) ms, \(bodies) redraws, \(total) ms total")
	}
}

/// What the player screen is asked to play.
struct PlayRequest: Identifiable, Equatable {
	let id = UUID()
	let url: String
	let title: String
	let channelKey: String
	/// Catch-up, a recording or a file: not the live edge, no reconnects.
	let catchup: Bool
	let channel: Channel?
	let archiveStart: Int64?
	let archiveStop: Int64?
}

/// A title and a block of text in a sheet: details, account info, release notes.
struct InfoText: Identifiable {
	let id = UUID()
	let title: String
	let text: String
}

/// Screens pushed on the main navigation stack.
enum Route: Hashable {
	case sources, onNow, guideSearch, recordings, settings, help
	case category(String)
	case channelGuide(String)
	case episodes(String)
}

/// Process-wide state: the Library (lists and guide), the status line, the player request.
@MainActor
final class AppModel: ObservableObject {
	static let shared = AppModel()

	let prefs: Prefs
	let library: Library
	let recorder: RecorderCenter

	/// The main screen's status line. Changes are spoken.
	@Published var status = ""
	/// Bumped when favourites, the guide or the lists change, so rows re-read them.
	@Published var revision = 0
	@Published private(set) var player: PlayerController?
	@Published var playerPresented = false
	@Published var info: InfoText?
	@Published var path: [Route] = []
	@Published var guidePath: [Route] = []
	@Published var selectedTab = 0
	/// Installed players to pick from for "Play in another app".
	@Published var externalChoice: [(String, URL)]?
	/// Set when playlists change so the main screen reloads on return.
	var sourcesChanged = false
	private var opening: Task<Void, Never>?

	/// Where lists, the guide and (tvOS) recordings live. tvOS has no persistent app storage
	/// beyond the cache, so it re-downloads after the system clears it.
	static var dataDir: URL {
		#if os(tvOS)
		let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
		#else
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		#endif
		return base.appendingPathComponent("AccessibleIPTV", isDirectory: true)
	}

	private init() {
		Strings.localize = { key, english in
			let s = NSLocalizedString(key, comment: "")
			return s == key ? english : s
		}
		Net.userAgent = "AccessibleIPTV-iOS/\(AppModel.version)"
		prefs = Prefs()
		do {
			library = try Library(dir: AppModel.dataDir, prefs: prefs)
		} catch {
			// A broken guide database must not stop the app: start over with an empty one.
			try? FileManager.default.removeItem(at: AppModel.dataDir.appendingPathComponent("epg.db"))
			library = try! Library(dir: AppModel.dataDir, prefs: prefs)
		}
		library.readFile = Bookmarks.read
		recorder = RecorderCenter(prefs: prefs)
		recorder.library = library
	}

	static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

	/// Sets the status line and speaks it, like the Android status live region.
	func setStatus(_ text: String) {
		status = text
		announce(text)
	}

	func refresh() { revision += 1 }
	func navigate(_ route: Route) {
		if selectedTab == 1 { guidePath.append(route) } else { path.append(route) }
	}

	/// Plays any list entry: shows open their episode list; Stalker links are fetched first.
	func open(_ ch: Channel, external: Bool = false) {
		opening?.cancel()
		if ch.kind == Channel.kindSeries { path.append(.episodes(ch.key)); return }
		// Recently watched / Previous channel: live channels only, as on the desktop.
		if ch.isLive { prefs.addRecent(ch.key) }
		if !ch.needsResolve {
			external ? ExternalPlayers.offer(ch.url, title: ch.name) : play(ch.url, title: ch.name, key: ch.key, channel: ch)
			return
		}
		setStatus(L("connecting"))
		opening = Task {
			do {
				let url = try await library.resolveUrl(ch)
				guard !Task.isCancelled else { return }
				external ? ExternalPlayers.offer(url, title: ch.name) : play(url, title: ch.name, key: ch.key, channel: ch)
				status = ""
			} catch {
				guard !Task.isCancelled else { return }
				setStatus(L("play_failed", error.localizedDescription))
			}
		}
	}

	func play(_ url: String, title: String, key: String, catchup: Bool = false, channel: Channel? = nil,
		archiveStart: Int64? = nil, archiveStop: Int64? = nil, fromSharePlay: Bool = false) {
		if prefs.useExternalPlayer && !fromSharePlay && !SharePlayCenter.shared.isActive { ExternalPlayers.offer(url, title: title); return }
		stopPlayback(leavingSharePlay: false)
		let request = PlayRequest(url: url, title: title, channelKey: key, catchup: catchup,
			channel: channel ?? library.channel(key), archiveStart: archiveStart, archiveStop: archiveStop)
		let controller = PlayerController(request: request)
		player = controller
		// A SharePlay host opens the provider once, through its relay; never directly as well.
		controller.start(openNow: !SharePlayCenter.shared.hostsNextPlayer(fromSession: fromSharePlay))
		controller.scene(UIApplication.shared.applicationState == .background ? .background : .active)
		playerPresented = true
		SharePlayCenter.shared.playerChanged(controller, fromSession: fromSharePlay)
		#if os(iOS)
		if !fromSharePlay, !catchup, let ch = request.channel { SiriIndex.tuned(ch) }
		#endif
	}

	func minimizePlayer() {
		player?.fullscreen = false
		playerPresented = false
	}

	func stopPlayback(leavingSharePlay: Bool = true) {
		SharePlayCenter.shared.cancelActivation()
		opening?.cancel()
		opening = nil
		// The relay stops first, so leaving SharePlay does not reopen the provider for a closing player.
		if let player { SharePlayCenter.shared.playerClosing(player) }
		if leavingSharePlay { SharePlayCenter.shared.leave() }
		player?.close()
		player = nil
		playerPresented = false
	}

	func showInfo(_ title: String, _ text: String) { info = InfoText(title: title, text: text) }
}

/// M3U files picked in Files: kept as security-scoped bookmarks, so a refresh re-reads the
/// file where it is (the Android app keeps the content:// permission the same way).
enum Bookmarks {
	static func make(_ url: URL) throws -> String {
		let ok = url.startAccessingSecurityScopedResource()
		defer { if ok { url.stopAccessingSecurityScopedResource() } }
		#if os(tvOS)
		let data = try url.bookmarkData()
		#else
		let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
		#endif
		return Source.fileScheme + data.base64EncodedString()
	}

	static func read(_ value: String) throws -> String {
		guard let data = Data(base64Encoded: String(value.dropFirst(Source.fileScheme.count))) else { throw CocoaError(.fileReadCorruptFile) }
		var stale = false
		let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
		let ok = url.startAccessingSecurityScopedResource()
		defer { if ok { url.stopAccessingSecurityScopedResource() } }
		let raw = try Data(contentsOf: url)
		return String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
	}
}
