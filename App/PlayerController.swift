import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import VLCKit
import IPTVCore
import GroupActivities

/// libVLC playback for every stream an IPTV provider sends (raw MPEG-TS, HLS, MKV, MP4),
/// with the desktop client's live cushion and reconnects. AVPlayer cannot play raw TS.
@MainActor
final class PlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
	@Published var status = ""
	@Published var isPlaying = false
	@Published var failed = false
	@Published var nowPlaying = ""
	@Published var subtitle = ""
	@Published var casting: String?
	@Published var fullscreen = false
	@Published private(set) var isPaused = false

	let player = VLCMediaPlayer()
	let videoSurface = UIView()
	let request: PlayRequest
	private let model = AppModel.shared
	private var prefs: Prefs { model.prefs }
	/// A live channel (not catch-up, a file or VOD): drops are reconnected like the desktop.
	let live: Bool
	let localFile: Bool
	private let reconnect = Reconnect(clock: nowMs)
	private var hasPlayed = false
	private var buffering = false
	private var stalls = 0
	private var cacheSeconds = Cushion.quickStartSeconds
	private var paced: Float = 1
	private var closing = false
	private var started = false
	private var intent = PlaybackIntent()
	private var observers: [NSObjectProtocol] = []
	private var remoteTargets: [(MPRemoteCommand, Any)] = []
	private var retryTask: Task<Void, Never>?
	private var timers: [Timer] = []
	/// Runs until the audio track is chosen (about ten seconds at most), then stops.
	private var trackTimer: Timer?
	/// Runs only while a subtitle file's cues are loaded.
	private var cueTimer: Timer?
	private var programmeTimer: Timer?
	private var autoTrackTries = 0
	private var autoTrackDone = false
	private var cues: [SubtitleCues.Cue] = []
	private var cueIndex: Int?
	private var videoOff = false
	private var sharePlayback: SharePlaybackCoordinator?
	private var sharedPausePending = false
	private var sharedPauseTemporary = false
	private var sharedSeekTarget: Double?
	/// SharePlay relay: the loopback stream this device plays instead of the provider URL.
	private var relayURL: String?
	/// Pause and play in a relayed session go to the host, which tells everyone.
	private var relayRequest: ((_ pause: Bool) -> Void)?
	#if os(iOS)
	private var discoverers: [VLCRendererDiscoverer] = []
	#endif

	init(request: PlayRequest) {
		self.request = request
		let ch = request.channel
		channel = ch
		live = !request.catchup && ch?.isLive == true
		localFile = request.url.hasPrefix("file:")
		super.init()
		videoSurface.backgroundColor = .black
		videoSurface.isAccessibilityElement = false
		player.drawable = videoSurface
		player.delegate = self
	}

	/// Looked up once: Library.channel scans every loaded list, movies included.
	let channel: Channel?

	// MARK: lifecycle

	/// `openNow` false: a SharePlay host waits for its relay instead of opening the provider.
	func start(openNow: Bool = true) {
		guard !started else { return }
		started = true
		#if os(iOS)
		CarAudio.shared.stop()
		#endif
		observeAudioSession()
		registerRemoteCommands()
		let audioReady = activateAudio()
		UIApplication.shared.isIdleTimerDisabled = true
		showProgramme(announce: false)
		if audioReady && openNow {
			open()
			say(L("connecting"), 2)
		}
		// Quick start, then build the cushion: a live stream plays 5% slow until it is held.
		if live { timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.pace() } }) }
		trackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoTrack() } }
		nowPlayingInfo()
		#if os(iOS)
		// Warm the cast device list so Cast has names to offer straight away.
		if !localFile {
			for d in VLCRendererDiscoverer.list() ?? [] {
				if let r = VLCRendererDiscoverer(name: d.name), r.start() { discoverers.append(r) }
			}
		}
		#endif
	}

	func close() {
		guard !closing else { return }
		closing = true
		leaveSharePlay()
		intent.pause()
		observers.forEach { NotificationCenter.default.removeObserver($0) }
		observers.removeAll()
		remoteTargets.forEach { $0.0.removeTarget($0.1) }
		remoteTargets.removeAll()
		retryTask?.cancel()
		timers.forEach { $0.invalidate() }
		trackTimer?.invalidate()
		cueTimer?.invalidate()
		programmeTimer?.invalidate()
		player.stop()
		player.drawable = nil
		player.delegate = nil
		#if os(iOS)
		discoverers.forEach { $0.stop() }
		#endif
		UIApplication.shared.isIdleTimerDisabled = false
		// CarPlay owns its own lock-screen title and commands. Closing the phone session must
		// leave those intact if CarPlay is already playing; otherwise its sound would continue
		// with a dead Now Playing card.
		#if os(iOS)
		let ownsNowPlaying = !CarAudio.shared.isPlaying
		#else
		let ownsNowPlaying = true
		#endif
		if ownsNowPlaying {
			MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
			if !model.recorder.needsBackgroundAudio {
				do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
				catch { model.setStatus(L("play_failed", error.localizedDescription)) }
			}
		}
	}

	/// Opens the stream. A first start and a reconnect wait for half a second of cache; the
	/// rest of the cushion is built by pace().
	/// The provider's stream with its M3U headers: user agent, referrer and cookie.
	static func providerMedia(_ address: String) -> VLCMedia? {
		let (plain, headers) = M3U.splitHeaders(address)
		guard let url = URL(string: plain) ?? (try? Net.url(plain)), let media = VLCMedia(url: url) else { return nil }
		media.addOption(":http-user-agent=\(headers["User-Agent"] ?? Net.userAgent)")
		if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
		if let cookie = headers["Cookie"], let host = url.host { _ = media.storeCookie(cookie, forHost: host, path: "/") }
		return media
	}

	private func open() {
		guard !closing, intent.canPlay else { return }
		if let relayURL {
			guard let url = URL(string: relayURL), let media = VLCMedia(url: url) else { return }
			// Relayed chunks arrive every two seconds; the cache rides over the gaps.
			for opt in ["network-caching", "live-caching"] { media.addOption(":\(opt)=3000") }
			hasPlayed = false
			buffering = false
			paced = 1
			player.rate = 1
			player.media = media
			player.play()
			return
		}
		guard let media = Self.providerMedia(request.url) else {
			say(L("play_failed", M3U.splitHeaders(request.url).0), 1)
			failed = true
			return
		}
		let ms: Int
		if live {
			let target = Cushion.target(base: prefs.bufferSeconds, max: prefs.maxBufferSeconds, stalls: stalls)
			cacheSeconds = min(target, Cushion.quickStartSeconds)
			ms = Int(cacheSeconds * 1000)
			// Live: drop late frames so playback stays at real time instead of drifting behind.
			media.addOption(":clock-jitter=1500")
		} else {
			// ponytail: VOD and catch-up start on a fixed 2 s cache; files seek, so no cushion is built.
			ms = localFile ? 300 : 2000
			media.addOption(":clock-jitter=0")
			media.addOption(":clock-synchro=0")
			media.addOption(":drop-late-frames=0")
			media.addOption(":skip-frames=0")
		}
		for opt in ["network-caching", "live-caching", "file-caching"] { media.addOption(":\(opt)=\(ms)") }
		media.addOption(":adaptive-use-access=1")
		hasPlayed = false
		buffering = false
		paced = 1
		player.media = media
		player.play()
	}

	// MARK: VLC events

	nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
		Task { @MainActor in self.stateChanged(newState) }
	}

	nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
		Task { @MainActor in self.bufferingChanged(progress) }
	}

	private func stateChanged(_ s: VLCMediaPlayerState) {
		guard !closing else { return }
		if s == .playing {
			let becameReady = !hasPlayed
			hasPlayed = true
			failed = false
			if sharedPausePending { performSharedPause(temporary: sharedPauseTemporary) }
			if becameReady { sharePlayback?.reapply() }
		}
		if s == .playing && !intent.canPlay { player.pause(); return }
		let playing = s == .playing
		if playing != isPlaying {
			isPlaying = playing
			if playing { say(L("playing"), 3) }
			nowPlayingInfo()
		}
		switch s {
		case .playing:
			if videoOff { player.deselectAllVideoTracks() }
			hasPlayed = true
			failed = false
		case .error:
			if tryReconnect() { return }
			say(L("play_failed", VLCLibrary.currentErrorMessage ?? ""), 1)
			failed = true
		case .stopped:
			guard intent.canPlay else { return }
			// A live stream that ends was dropped by the server: reconnect, as the desktop does.
			// Casting stops the player on purpose and announces it, so this is not a drop.
			if retryTask != nil || casting != nil || tryReconnect() { return }
			say(L("stream_ended"), 1)
			failed = true
		default:
			break
		}
	}

	/// Buffering after playback began is a stall: the cushion grows a second, like the desktop.
	private func bufferingChanged(_ progress: Float) {
		guard hasPlayed, !closing else { return }
		if progress < 100 && !buffering {
			buffering = true
			stalls += 1
			say(L("buffering"), 3)
		} else if progress >= 100 {
			let recovered = buffering
			buffering = false
			if recovered { sharePlayback?.reapply() }
		}
	}

	/// Schedules the next reconnect of a live stream; false when this stream does not get one.
	private func tryReconnect() -> Bool {
		guard intent.canPlay, live, casting == nil, let delay = reconnect.next() else { return false }
		say(L("reconnecting"), 2)
		retryTask?.cancel()
		retryTask = Task {
			try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
			guard !Task.isCancelled, !closing, intent.canPlay else { return }
			retryTask = nil
			// Behind the live window after a drop: start again at the live edge.
			open()
		}
		return true
	}

	// MARK: controls

	func togglePause() {
		if intent.canPlay && !failed { pause() } else { resume() }
	}

	func pause() {
		guard !closing else { return }
		if let relayRequest { relayRequest(true); return }
		if let sharePlayback {
			intent.pause()
			isPaused = true
			sharePlayback.pause()
			return
		}
		pauseLocally()
	}

	private func pauseLocally() {
		intent.pause()
		isPaused = true
		UIApplication.shared.isIdleTimerDisabled = false
		retryTask?.cancel()
		retryTask = nil
		player.pause()
		isPlaying = false
		nowPlayingInfo()
	}

	func resume() {
		guard !closing else { return }
		if let relayRequest, !failed { relayRequest(false); return }
		if let sharePlayback {
			intent.play()
			isPaused = false
			guard activateAudio() else { return }
			sharePlayback.endSuspension()
			sharePlayback.play()
			return
		}
		resumeLocally()
	}

	private func resumeLocally() {
		intent.play()
		guard intent.canPlay, activateAudio() else { return }
		isPaused = false
		UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState == .active
		if failed || player.state == .stopped || player.state == .error {
			// Retry after a failure: a live stream starts again at the live edge.
			retryTask?.cancel()
			retryTask = nil
			reconnect.reset()
			failed = false
			open()
			return
		}
		player.play()
	}

	/// A status line, spoken only up to the Announcements level in Settings
	/// (desktop: 1 errors, 2 important events, 3 detailed status). The text always updates.
	func say(_ text: String, _ priority: Int) {
		guard !closing else { return }
		status = text
		if prefs.announceLevel >= priority { announce(text) }
	}

	/// Shows what is on and, when the guide says the programme changed, says "Now: ..."
	/// as an important event. Re-arms itself for the end of the programme. Live only.
	private func showProgramme(announce: Bool) {
		programmeTimer?.invalidate()
		guard live, let ch = channel else { nowPlaying = request.title; return }
		let nn = model.library.epg.nowNext(ch)
		if let on = nn.now {
			nowPlaying = Format.sentences([request.title, L("now_programme", Format.programme(on))])
			if announce { say(L("now_programme", Format.programme(on)), 2) }
		} else {
			nowPlaying = request.title
		}
		guard let change = nn.now?.stop ?? nn.next?.start else { return }
		let wait = max(1, Double(change - nowMs() + 2_000) / 1000)
		programmeTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in Task { @MainActor in self?.showProgramme(announce: true) } }
		nowPlayingInfo()
	}

	/// Plays a live stream slightly slow until the buffer setting is held locally.
	private func pace() {
		guard live, sharePlayback == nil, relayURL == nil, casting == nil, player.isPlaying, let media = player.media else { return }
		let stats = media.statistics
		let cushion = Cushion.liveCushionSeconds(readBytes: stats.readBytes, demuxBytes: stats.demuxReadBytes,
			playedMs: Int64(player.time.intValue), cacheSeconds: cacheSeconds)
		let want = Cushion.paceRate(cushion: cushion, target: Cushion.target(base: prefs.bufferSeconds, max: prefs.maxBufferSeconds, stalls: stalls), current: paced)
		if want != paced {
			paced = want
			player.rate = want
		}
	}

	// MARK: audio tracks

	struct TrackChoice { let name: String; let track: VLCMediaPlayer.Track }

	func audioTracks() -> [TrackChoice] { named(player.audioTracks) }
	func textTracks() -> [TrackChoice] { named(player.textTracks) }

	private func named(_ tracks: [VLCMediaPlayer.Track]) -> [TrackChoice] {
		tracks.enumerated().map { i, t in
			var parts = [t.trackName]
			if let l = t.language, !l.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
			if let d = t.trackDescription, !d.isEmpty { parts.append(d) }
			var seen = Set<String>()
			let name = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
			return TrackChoice(name: name.isEmpty ? L("track_n", i + 1) : name, track: t)
		}
	}

	/// Audio description, a remembered track or a preferred language, picked once the
	/// stream's tracks are known (they arrive late: tried for ten seconds, like the desktop).
	private func autoTrack() {
		if autoTrackDone { trackTimer?.invalidate(); trackTimer = nil; return }
		guard hasPlayed else { return }
		autoTrackTries += 1
		let audio = audioTracks()
		if autoTrackTries > 20 { autoTrackDone = true; return }
		guard !audio.isEmpty else { return }
		let idx = AudioTracks.choose(
			names: audio.map(\.name),
			describesVideo: audio.map { _ in false },
			remembered: prefs.rememberedTrack(request.channelKey),
			preferAd: prefs.preferAudioDescription,
			keywords: prefs.audioKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		)
		if idx >= 0 {
			if !audio[idx].track.isSelected { audio[idx].track.isSelectedExclusively = true }
			autoTrackDone = true
		} else if autoTrackTries >= 6 {
			autoTrackDone = true
		}
	}

	func selectAudio(_ c: TrackChoice) {
		c.track.isSelectedExclusively = true
		autoTrackDone = true
		// Remembered per channel, ahead of every other rule, like the desktop app.
		if !request.channelKey.isEmpty { prefs.rememberTrack(request.channelKey, c.name) }
		say(L("audio_track_set", c.name), 2)
	}

	// MARK: subtitles

	func selectSubtitle(_ c: TrackChoice?) {
		if let c {
			c.track.isSelectedExclusively = true
			say(L("subtitles_set", c.name), 2)
		} else {
			player.deselectAllTextTracks()
			subtitle = ""
			say(L("subtitles_set", L("subtitles_off")), 2)
		}
	}

	/// Loads an SRT/VTT (or other) subtitle file. libVLC shows it; SRT and WebVTT are also
	/// spoken, since only their text can be read back (desktop subtitle_cues).
	func loadSubtitle(_ picked: URL) {
		let ok = picked.startAccessingSecurityScopedResource()
		defer { if ok { picked.stopAccessingSecurityScopedResource() } }
		let copy = FileManager.default.temporaryDirectory.appendingPathComponent(picked.lastPathComponent)
		try? FileManager.default.removeItem(at: copy)
		do {
			try FileManager.default.copyItem(at: picked, to: copy)
		} catch {
			say(L("play_failed", error.localizedDescription), 1)
			return
		}
		_ = player.addPlaybackSlave(copy, type: .subtitle, enforce: true)
		say(L("subtitles_set", picked.lastPathComponent), 2)
		cues = []
		cueIndex = nil
		if SubtitleCues.speakableExtensions.contains(copy.pathExtension.lowercased()), let raw = try? Data(contentsOf: copy) {
			cues = SubtitleCues.parse(String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self))
			if !cues.isEmpty && cueTimer == nil {
				cueTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.cueTick() } }
			}
		} else if prefs.speakSubtitles {
			say(L("subtitle_speech_needs_text"), 1)
		}
	}

	private func cueTick() {
		guard !cues.isEmpty else { return }
		let off = !player.textTracks.contains { $0.isSelected }
		// The subtitle delay is in microseconds; a positive delay shows cues later.
		let ms = Int64(player.time.intValue) - Int64(player.currentVideoSubTitleDelay / 1000)
		let index = off || ms < 0 ? nil : SubtitleCues.active(cues, ms)
		guard index != cueIndex else { return }
		cueIndex = index
		let text = index.map { cues[$0].text } ?? ""
		subtitle = text
		if !text.isEmpty && prefs.speakSubtitles && player.isPlaying { announce(text) }
	}

	// MARK: cast

	#if os(iOS)
	struct Renderer { let name: String; let item: VLCRendererItem }

	func renderers() -> [Renderer] {
		var seen = Set<String>()
		return discoverers.flatMap { $0.renderers }.filter { seen.insert($0.name).inserted }.map { Renderer(name: $0.name, item: $0) }
	}

	/// Moves playback to a Chromecast (libVLC's renderer), or back to this device.
	func cast(to r: Renderer?) {
		if sharePlayback != nil || relayURL != nil {
			SharePlayCenter.shared.leave()
			relayURL = nil
			relayRequest = nil
		}
		let position = player.position
		player.stop()
		_ = player.setRendererItem(r?.item)
		casting = r?.name
		open()
		if !live && position > 0 { player.position = position }
		say(r.map { L("casting_to", $0.name) } ?? L("cast_stopped"), 2)
	}
	#endif

	// MARK: background and lock screen

	/// In the background the video is switched off and the sound keeps playing; back in the
	/// app, the picture returns.
	func scene(_ phase: ScenePhase) {
		UIApplication.shared.isIdleTimerDisabled = phase == .active && !isPaused
		if phase == .background && casting == nil && !videoOff {
			videoOff = true
			player.deselectAllVideoTracks()
			player.drawable = nil
		} else if phase == .active && videoOff {
			videoOff = false
			player.drawable = videoSurface
			if !player.videoTracks.isEmpty { player.selectTrack(at: 0, type: .video) }
		}
	}

	private func activateAudio() -> Bool {
		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, mode: .moviePlayback)
			try session.setActive(true)
			return true
		} catch {
			failed = true
			say(L("play_failed", error.localizedDescription), 1)
			return false
		}
	}

	private func observeAudioSession() {
		let center = NotificationCenter.default
		observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
			Task { @MainActor in self?.interruption(note) }
		})
		observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
			guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
				AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
			Task { @MainActor in
				guard let self else { return }
				self.sharePlayback?.suspend()
				self.pauseLocally()
			}
		})
	}

	private func interruption(_ note: Notification) {
		guard !closing, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
			let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
		if type == .began {
			sharePlayback?.suspend()
			intent.beginInterruption()
			isPaused = true
			retryTask?.cancel()
			retryTask = nil
			player.pause()
			isPlaying = false
			nowPlayingInfo()
		} else {
			let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
			if intent.endInterruption(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)) {
				if let sharePlayback {
					if activateAudio() { sharePlayback.endSuspension(); sharePlayback.reapply() }
				} else { resume() }
			} else {
				isPaused = true
			}
		}
	}

	// MARK: SharePlay relay

	var isRelayed: Bool { relayURL != nil }

	/// Plays the relay at `url` (nil: back to the provider). `request` sends pause and play to the host.
	func useRelay(_ url: String?, request: ((_ pause: Bool) -> Void)?) {
		guard !closing else { return }
		leaveSharePlay()
		relayURL = url
		relayRequest = request
		retryTask?.cancel()
		retryTask = nil
		reconnect.reset()
		failed = false
		player.stop()
		open()
	}

	/// The host paused or resumed everyone. `rejoin`: a live relay starts again at its edge.
	func relayPaused(_ paused: Bool, rejoin: Bool) {
		guard !closing else { return }
		if paused { pauseLocally(); return }
		guard rejoin else { resumeLocally(); return }
		intent.play()
		guard intent.canPlay, activateAudio() else { return }
		isPaused = false
		player.stop()
		open()
	}

	// MARK: SharePlay's native custom-player adapter

	var isSharingPlayback: Bool { sharePlayback != nil }
	var sharedPlaybackTime: Double { max(0, Double(player.time.intValue) / 1000) }
	var sharedPlaybackRate: Float { isPaused ? 0 : 1 }
	var sharedPlaybackReady: Bool {
		guard hasPlayed, !buffering, !failed, !closing, retryTask == nil,
			player.state == .playing || player.state == .paused else { return false }
		if let target = sharedSeekTarget {
			guard abs(sharedPlaybackTime - target) < 0.5 else { return false }
			sharedSeekTarget = nil
		}
		return true
	}
	var sharedPlaybackSeekable: Bool { !live && player.isSeekable }
	var sharedPlaybackFailed: Bool { failed || closing }

	func joinSharePlay(_ session: GroupSession<WatchTVActivity>, identifier: String) {
		leaveSharePlay()
		player.rate = 1
		paced = 1
		let adapter = SharePlaybackCoordinator(controller: self, identifier: identifier)
		sharePlayback = adapter
		adapter.join(session)
	}

	func leaveSharePlay() {
		let resume = sharePlayback != nil && sharedPausePending && sharedPauseTemporary && intent.canPlay && !closing
		sharePlayback?.close()
		sharePlayback = nil
		sharedPausePending = false
		sharedSeekTarget = nil
		if resume { resumeLocally() }
	}

	func performSharedPause(temporary: Bool = false) {
		guard !closing else { return }
		sharedPausePending = true
		sharedPauseTemporary = temporary
		if !temporary { intent.pause(); isPaused = true }
		// Let VLC finish opening before pausing, so it can report readiness to SharePlay.
		if hasPlayed {
			if temporary {
				player.pause()
				isPlaying = false
				nowPlayingInfo()
			} else { pauseLocally() }
		}
	}

	func performSharedPlay(rate: Float) {
		guard !closing else { return }
		sharedPausePending = false
		resumeLocally()
		player.rate = rate
	}

	func performSharedSeek(seconds: Double) {
		guard sharedPlaybackSeekable, seconds.isFinite else { return }
		let target = min(Double(Int32.max) / 1000, max(0, seconds))
		guard abs(sharedPlaybackTime - target) > 0.2 else { return }
		sharedSeekTarget = target
		player.time = VLCTime(int: Int32(target * 1000))
	}

	func recoverSharedPlayback() {
		guard !closing, sharePlayback != nil else { return }
		intent.play()
		guard intent.canPlay, activateAudio() else { return }
		retryTask?.cancel()
		retryTask = nil
		reconnect.reset()
		failed = false
		sharedPausePending = true
		sharedPauseTemporary = true
		sharedSeekTarget = nil
		open()
	}

	private func registerRemoteCommands() {
		let rc = MPRemoteCommandCenter.shared()
		for command in [rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand, rc.stopCommand] { command.isEnabled = true }
		remoteTargets = [
			(rc.playCommand, rc.playCommand.addTarget { [weak self] _ in
				Task { @MainActor in self?.resume() }; return .success
			}),
			(rc.pauseCommand, rc.pauseCommand.addTarget { [weak self] _ in
				Task { @MainActor in self?.pause() }; return .success
			}),
			(rc.togglePlayPauseCommand, rc.togglePlayPauseCommand.addTarget { [weak self] _ in
				Task { @MainActor in self?.togglePause() }; return .success
			}),
			(rc.stopCommand, rc.stopCommand.addTarget { [weak self] _ in
				Task { @MainActor in self?.model.stopPlayback() }; return .success
			}),
		]
	}

	private func nowPlayingInfo() {
		guard !closing else { return }
		MPNowPlayingInfoCenter.default().nowPlayingInfo = [
			MPMediaItemPropertyTitle: nowPlaying.isEmpty ? request.title : nowPlaying,
			MPNowPlayingInfoPropertyIsLiveStream: live,
			MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.rate) : 0.0,
		]
	}
}
