#if os(iOS)
import CarPlay
import MediaPlayer
import VLCKit
import IPTVCore

/// CarPlay: Favourites and Recently watched live channels, played as sound only (CarPlay
/// shows no video while driving). Needs the CarPlay audio entitlement in the signing profile.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
	private var interface: CPInterfaceController?

	func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
		interface = interfaceController
		Task { @MainActor in
			let model = AppModel.shared
			if !model.library.isLoaded(Library.live) { _ = await model.library.load(Library.live, force: false) }
			interfaceController.setRootTemplate(self.root(model), animated: false, completion: nil)
		}
	}

	func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
		interface = nil
	}

	@MainActor private func root(_ model: AppModel) -> CPListTemplate {
		let live = model.library.channels
		var byKey: [String: Channel] = [:]
		for c in live { byKey[c.key] = c }
		let favs = model.prefs.favorites
		let favourites = live.filter { favs.contains($0.key) }
		let recent = model.prefs.recent.compactMap { byKey[$0] }
		let t = CPListTemplate(title: L("app_name"), sections: [
			CPListSection(items: favourites.map(item), header: L("favorites"), sectionIndexTitle: nil),
			CPListSection(items: recent.map(item), header: L("recently_watched"), sectionIndexTitle: nil),
		])
		t.emptyViewSubtitleVariants = [L("no_sources")]
		return t
	}

	@MainActor private func item(_ ch: Channel) -> CPListItem {
		let now = AppModel.shared.library.epg.nowNext(ch).now
		let i = CPListItem(text: ch.name, detailText: now.map { L("until", $0.title, Format.time($0.stop)) })
		i.handler = { [weak self] _, done in
			Task { @MainActor in
				await CarAudio.shared.play(ch)
				self?.interface?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
				done()
			}
		}
		return i
	}
}

/// Sound-only libVLC playback for CarPlay, with the lock screen and steering-wheel controls.
@MainActor
final class CarAudio {
	static let shared = CarAudio()
	private let player = VLCMediaPlayer()

	func play(_ ch: Channel) async {
		let model = AppModel.shared
		model.playing = nil
		model.prefs.addRecent(ch.key)
		guard let raw = try? await model.library.resolveUrl(ch) else { return }
		let (plain, headers) = M3U.splitHeaders(raw)
		guard let url = URL(string: plain), let media = VLCMedia(url: url) else { return }
		media.addOption(":no-video")
		media.addOption(":http-user-agent=\(headers["User-Agent"] ?? Net.userAgent)")
		media.addOption(":network-caching=3000")
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
		try? AVAudioSession.sharedInstance().setActive(true)
		player.media = media
		player.play()
		MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: ch.name, MPNowPlayingInfoPropertyIsLiveStream: true]
		let rc = MPRemoteCommandCenter.shared()
		[rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand].forEach { $0.removeTarget(nil) }
		rc.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
		rc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
		rc.togglePlayPauseCommand.addTarget { [weak self] _ in
			guard let p = self?.player else { return .commandFailed }
			p.isPlaying ? p.pause() : p.play()
			return .success
		}
	}

	func stop() { player.stop() }
}
#endif
