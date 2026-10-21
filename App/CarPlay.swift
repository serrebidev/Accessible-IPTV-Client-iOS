#if os(iOS)
import CarPlay
import MediaPlayer
import SwiftVLC
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
	private let player = Player(instance: .app)
	private var events: Task<Void, Never>?
	private var connectionID: UUID?
	/// The channel being played, kept so a dropped stream can reopen it.
	private var current: (channel: Channel, raw: String)?
	/// False once stop() is called on purpose: a deliberate stop is not a drop.
	private var wanted = false
	/// Our own teardown stop while reopening must not be read as another drop.
	private var reopening = false
	private var retryTask: Task<Void, Never>?
	private let reconnect = Reconnect(clock: nowMs)

	func play(_ ch: Channel) async {
		let model = AppModel.shared
		stop()
		let id = UUID()
		connectionID = id
		model.stopPlayback()
		let ready = await PlaybackTeardown.ready()
		guard connectionID == id else { return }
		guard ready else { stop(); model.setStatus(L("play_failed", URLError(.timedOut).localizedDescription)); return }
		let acquired = await MediaConnection.shared.acquire(id)
		guard connectionID == id else {
			if acquired { MediaConnection.shared.release(id) { await PlaybackTeardown.finished() } }
			return
		}
		guard acquired else { stop(); model.setStatus(L("single_connection_busy")); return }
		model.rememberChannel(ch)
		let raw = try? await model.library.resolveUrl(ch)
		guard connectionID == id, !Task.isCancelled else {
			if connectionID == id { stop() }
			return
		}
		guard let raw else { stop(); model.setStatus(L("play_failed", ch.name)); return }
		current = (ch, raw)
		wanted = true
		reconnect.reset()
		observe()
		model.setStatus(L("connecting"))
		open(raw)
		MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: ch.name, MPNowPlayingInfoPropertyIsLiveStream: true]
		let rc = MPRemoteCommandCenter.shared()
		[rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand].forEach { $0.removeTarget(nil) }
		rc.playCommand.addTarget { [weak self] _ in
			Task { @MainActor in if let self { PlaybackTeardown.play(self.player) } }; return .success
		}
		rc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
		rc.togglePlayPauseCommand.addTarget { [weak self] _ in
			guard let p = self?.player else { return .commandFailed }
			Task { @MainActor in p.isPlaying ? p.pause() : PlaybackTeardown.play(p) }
			return .success
		}
	}

	/// (Re)opens the current channel's stream.
	private func open(_ raw: String) {
		let model = AppModel.shared
		let (plain, headers) = M3U.splitHeaders(raw)
		guard let url = URL(string: plain), let media = try? Media(url: url) else {
			if let ch = current?.channel { stop(); model.setStatus(L("play_failed", ch.name)) }
			return
		}
		media.addOption(":no-video")
		media.setHTTPUserAgent(headers["User-Agent"] ?? Net.userAgent)
		StreamOptions.network(url, live: true, cacheMs: 3000).forEach { media.addOption($0) }
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
		try? AVAudioSession.sharedInstance().setActive(true)
		PlaybackTeardown.play(player, media)
	}

	private func observe() {
		guard events == nil else { return }
		let stream = player.events
		events = Task { [weak self] in
			for await event in stream {
				guard let self else { return }
				guard case .stateChanged(let state) = event, self.wanted, self.player.state == state else { continue }
				if state == .error || state == .stopped { self.recover() }
			}
		}
	}

	/// A dropped CarPlay stream reopens inside the same budget as the player screen;
	/// when the budget is spent the channel is declared lost instead of ending silently.
	private func recover() {
		guard wanted, !reopening, retryTask == nil, let raw = current?.raw else { return }
		guard let delay = reconnect.next() else {
			stop()
			AppModel.shared.setStatus(L("stream_lost"))
			return
		}
		AppModel.shared.setStatus(L("reconnecting"))
		retryTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
			guard let self, !Task.isCancelled, self.wanted else { return }
			self.retryTask = nil
			self.reopening = true
			// Wait for the dropped reader to close before reopening, like the player screen.
			PlaybackTeardown.stop(self.player)
			let ready = await PlaybackTeardown.ready()
			self.reopening = false
			guard ready else { self.recover(); return }
			guard self.wanted else { return }
			self.open(raw)
		}
	}

	func stop() {
		wanted = false
		current = nil
		retryTask?.cancel()
		retryTask = nil
		PlaybackTeardown.stop(player)
		if let id = connectionID { MediaConnection.shared.release(id) { await PlaybackTeardown.finished() } }
		connectionID = nil
		// CarAudio is the owner of the lock screen while it plays: it clears what it set, so the
		// card does not outlive the sound (the player screen knows to leave it alone, see close).
		MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
		let rc = MPRemoteCommandCenter.shared()
		[rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand].forEach { $0.removeTarget(nil) }
	}

	/// Whether CarAudio holds the lock screen and the remote commands right now.
	var isPlaying: Bool { player.isPlaying }
}
#endif
