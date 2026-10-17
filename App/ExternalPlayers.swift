import SwiftUI
import UIKit
import IPTVCore

/// "Play in another app": iOS has no "open with" chooser for a stream URL, so the players
/// that take one by URL scheme are offered, those installed only.
enum ExternalPlayers {
	struct App {
		let name: String
		let link: (String) -> String?
	}

	private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

	static let apps: [App] = [
		App(name: "VLC") { "vlc-x-callback://x-callback-url/stream?url=\(enc($0))" },
		App(name: "Infuse") { "infuse://x-callback-url/play?url=\(enc($0))" },
		App(name: "nPlayer") { "nplayer-\($0)" },
		App(name: "Outplayer") { "outplayer://\($0)" },
	]

	/// Shows the installed players (one goes straight there); none: says so.
	@MainActor static func offer(_ url: String, title: String) {
		let plain = M3U.splitHeaders(url).0
		let installed = apps.compactMap { a -> (String, URL)? in
			guard let s = a.link(plain), let u = URL(string: s), UIApplication.shared.canOpenURL(u) else { return nil }
			return (a.name, u)
		}
		let model = AppModel.shared
		switch installed.count {
		case 0: model.showInfo(L("play_external"), L("no_external_player"))
		case 1:
			open(installed[0].1)
		default: model.externalChoice = installed
		}
	}

	@MainActor static func open(_ url: URL) {
		let model = AppModel.shared
		model.stopPlayback()
		#if os(iOS)
		CarAudio.shared.stop()
		#endif
		Task { @MainActor in
			guard await PlaybackTeardown.ready() else {
				model.setStatus(L("play_failed", URLError(.timedOut).localizedDescription)); return
			}
			let id = UUID()
			guard await MediaConnection.shared.acquire(id) else { model.setStatus(L("single_connection_busy")); return }
			let opened = await UIApplication.shared.open(url)
			// External apps own their transport after handoff; iOS cannot monitor or stop it.
			MediaConnection.shared.release(id)
			if !opened { model.setStatus(L("no_external_player")) }
		}
	}

	#if os(iOS) || os(visionOS)
	/// Hands a saved recording to another app through the share sheet.
	@MainActor static func share(_ file: URL) {
		let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
		guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else { return }
		var top = root
		while let p = top.presentedViewController { top = p }
		vc.popoverPresentationController?.sourceView = top.view
		top.present(vc, animated: true)
	}
	#endif
}
