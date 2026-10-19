import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit
import VLCKit
import IPTVCore
import GroupActivities
import OSLog

/// Native playback and AirPlay for compatible media; VLC handles raw TS and other IPTV formats.
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
	@Published private(set) var usesNative: Bool
	@Published private(set) var nativeVideoAttached = true
	let nativePlayer = AVPlayer()
	private var nativeObservations: [NSKeyValueObservation] = []
	private var nativeNotifications: [NSObjectProtocol] = []
	private var nativeTimeout: Task<Void, Never>?
	private var nativeTracksTask: Task<Void, Never>?
	private var nativeAudio: [TrackChoice] = []
	private var nativeText: [TrackChoice] = []
	private var fallbackTime: Double?
	private var airPlayRoute: String?
	private var preparingVideo = false
	private var relayStartTime = 0.0
	var isRelayingVideo: Bool {
		#if os(iOS)
		return videoRelay != nil || preparingVideo
		#else
		return false
		#endif
	}

	let player = VLCMediaPlayer()
	let videoSurface = UIView()
	let request: PlayRequest
	private let model = AppModel.shared
	private var prefs: Prefs { model.prefs }
	private var playbackURL: String {
		#if os(iOS)
		if let url = videoRelay?.url { return url.absoluteString }
		#endif
		return request.url
	}
	/// A live channel (not catch-up, a file or VOD): drops are reconnected like the desktop.
	let live: Bool
	let localFile: Bool
	private let reconnect = Reconnect(clock: nowMs)
	private var hasPlayed = false
	private var buffering = false
	private var stalls = 0
	private var cacheSeconds = Cushion.quickStartSeconds
	/// Set once this session has reopened after a stall: the reopen waits with the whole
	/// saved cushion, like the desktop, instead of the half-second quick start.
	private var reopened = false
	/// The desktop's playback-health rules, ticked once a second while playing.
	private var health = StallTracker()
	/// Media-progress sampling for the health tick: the last position seen, and since
	/// when it has stood still while the player claims to be playing.
	private var progress = PlaybackProgress()
	private static let playbackLog = Logger(subsystem: "dev.serrebi.accessibleiptv", category: "Playback")
	private var closing = false
	private let connectionID = UUID()
	private var started = false
	private var intent = PlaybackIntent()
	private var observers: [NSObjectProtocol] = []
	private var remoteTargets: [(MPRemoteCommand, Any)] = []
	private var retryTask: Task<Void, Never>?
	private var openingTask: Task<Void, Never>?
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
	private var pendingSubtitle: URL?
	private var loadedSubtitleFile: URL?
	private var selectedSubtitleName: String?
	private var videoOff = false
	private var sharePlayback: SharePlaybackCoordinator?
	private var sharedPausePending = false
	private var sharedPauseTemporary = false
	private var sharedSeekTarget: Double?
	#if os(iOS)
	private var discoverers: [VLCRendererDiscoverer] = []
	private var videoRelay: VideoRelay?
	private var castPreparation: Task<Void, Never>?
	#endif

	init(request: PlayRequest) {
		self.request = request
		usesNative = PlaybackBackend.preferred(for: request.url) == .native
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

	func start() {
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
		if audioReady {
			open()
			say(L("connecting"), 2)
		}
		let healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.healthTick() } }
		timers.append(healthTimer)
		restartTrackSelection()
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
		openingTask?.cancel()
		timers.forEach { $0.invalidate() }
		trackTimer?.invalidate()
		cueTimer?.invalidate()
		programmeTimer?.invalidate()
		stopNative()
		#if os(iOS)
		castPreparation?.cancel()
		videoRelay?.stop()
		videoRelay = nil
		#endif
		PlaybackTeardown.stop(player)
		player.drawable = nil
		player.delegate = nil
		MediaConnection.shared.release(connectionID) { await PlaybackTeardown.finished() }
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

	/// Opens the stream. A first start waits for half a second of cache; a reopen after a
	/// stall waits with the whole saved cushion (Cushion.openSeconds).
	private func open() {
		openingTask?.cancel()
		stopNative()
		PlaybackTeardown.stop(player)
		openingTask = Task { [weak self] in
			let ready = await PlaybackTeardown.ready()
			guard let self else { return }
			// Paused, closed or superseded while waiting: not a failure, and nothing to say.
			guard !Task.isCancelled, !self.closing, self.intent.canPlay else { return }
			guard ready else {
				self.openingTask = nil
				self.failed = true
				self.say(L("play_failed", URLError(.timedOut).localizedDescription), 1)
				return
			}
			if !self.localFile {
				guard await MediaConnection.shared.acquire(self.connectionID) else {
					// A pause or close that landed during the wait is not a busy provider.
					guard !Task.isCancelled, !self.closing, self.intent.canPlay else { return }
					self.openingTask = nil
					self.failed = true
					self.say(L("single_connection_busy"), 1)
					return
				}
				guard !Task.isCancelled, !self.closing, self.intent.canPlay else {
					// Claimed, then abandoned before opening: hand the slot back at once,
					// or it stays taken until this screen closes.
					MediaConnection.shared.release(self.connectionID) { await PlaybackTeardown.finished() }
					return
				}
			}
			self.openingTask = nil
			self.openNow()
		}
	}

	private func openNow() {
		guard !closing, intent.canPlay else { return }
		progress.reset()
		cacheSeconds = usesNative || !live
			? Cushion.target(base: prefs.bufferSeconds, max: prefs.maxBufferSeconds, stalls: stalls)
			: Cushion.openSeconds(base: prefs.bufferSeconds, max: prefs.maxBufferSeconds, stalls: stalls, reopened: reopened)
		health.prepared(caching: cacheSeconds)
		if usesNative { openNative(); return }
		let (plain, headers) = M3U.splitHeaders(playbackURL)
		guard let url = URL(string: plain) ?? (try? Net.url(plain)), let media = VLCMedia(url: url) else {
			say(L("play_failed", plain), 1)
			failed = true
			return
		}
		media.addOption(":http-user-agent=\(headers["User-Agent"] ?? Net.userAgent)")
		if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
		if let cookie = headers["Cookie"], let host = url.host { _ = media.storeCookie(cookie, forHost: host, path: "/") }
		let ms: Int
		if live {
			ms = Int(cacheSeconds * 1000)
			// Live: drop late frames so playback stays at real time instead of drifting behind.
			media.addOption(":clock-jitter=1500")
		} else {
			// VOD, catch-up and files open with the same full caching value as the desktop.
			ms = Int(cacheSeconds * 1000)
			media.addOption(":clock-jitter=0")
			media.addOption(":clock-synchro=0")
			media.addOption(":drop-late-frames=0")
			media.addOption(":skip-frames=0")
		}
		for opt in ["network-caching", "live-caching", "file-caching"] { media.addOption(":\(opt)=\(ms)") }
		media.addOption(":adaptive-use-access=1")
		media.addOption(":http-reconnect=true")
		media.addOption(":rtsp-tcp")
		hasPlayed = false
		buffering = false
		player.media = media
		PlaybackTeardown.play(player)
	}

	// MARK: native playback

	private func openNative() {
		let (plain, headers) = M3U.splitHeaders(playbackURL)
		guard let url = URL(string: plain) else { fallbackToVLC(); return }
		let agent = headers.first { $0.key.lowercased() == "user-agent" }?.value ?? Net.userAgent
		let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetHTTPUserAgentKey: agent]))
		// The forward buffer is the saved cushion for every kind, like the desktop's
		// caching value; a file or film used to get a flat 2 s here.
		item.preferredForwardBufferDuration = cacheSeconds
		hasPlayed = false
		buffering = false
		#if !os(visionOS)
		nativePlayer.allowsExternalPlayback = true
		#endif
		nativePlayer.replaceCurrentItem(with: item)
		nativeObservations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
			Task { @MainActor in
				guard let self, self.usesNative, self.nativePlayer.currentItem === item, !self.closing else { return }
				if item.status == .failed { self.fallbackToVLC(); return }
				if item.status == .readyToPlay {
					self.hasPlayed = true
					if !self.live, let time = self.fallbackTime, !self.isRelayingVideo {
						self.nativePlayer.seek(to: CMTime(seconds: time, preferredTimescale: 1000))
						self.fallbackTime = nil
					}
					if self.sharedPausePending { self.performSharedPause(temporary: self.sharedPauseTemporary) }
					self.sharePlayback?.reapply()
				}
			}
		})
		nativeObservations.append(nativePlayer.observe(\.timeControlStatus, options: [.new]) { [weak self, weak item] _, _ in
			Task { @MainActor in
				guard let self, let item, self.usesNative, self.nativePlayer.currentItem === item, !self.closing else { return }
				switch self.nativePlayer.timeControlStatus {
				case .playing:
					self.nativeTimeout?.cancel()
					self.bufferingChanged(1)
					self.stateChanged(.playing)
				case .waitingToPlayAtSpecifiedRate:
					self.bufferingChanged(0)
					self.armNativeTimeout()
				case .paused:
					self.isPlaying = false
					self.nowPlayingInfo()
				@unknown default: break
				}
			}
		})
		#if !os(visionOS)
		nativeObservations.append(nativePlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
			Task { @MainActor in self?.announceNativeRoute() }
		})
		#endif
		let center = NotificationCenter.default
		for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
			nativeNotifications.append(center.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] note in
				let failed = note.name == AVPlayerItem.failedToPlayToEndTimeNotification
				Task { @MainActor in
					guard let self, let item, self.usesNative, self.nativePlayer.currentItem === item, !self.closing else { return }
					if failed { self.fallbackToVLC() } else { self.stateChanged(.stopped) }
				}
			})
		}
		nativeTracksTask = Task { [weak self, weak item] in
			guard let item else { return }
			let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
			let text = try? await item.asset.loadMediaSelectionGroup(for: .legible)
			guard let self, !Task.isCancelled, self.usesNative, self.nativePlayer.currentItem === item else { return }
			self.nativeAudio = self.nativeChoices(audio)
			self.nativeText = self.nativeChoices(text)
			self.restartTrackSelection()
			self.autoTrack()
		}
		if intent.canPlay { nativePlayer.play(); armNativeTimeout() }
	}

	private func stopNative() {
		nativeTimeout?.cancel()
		nativeTracksTask?.cancel()
		nativeObservations.removeAll()
		nativeNotifications.forEach { NotificationCenter.default.removeObserver($0) }
		nativeNotifications.removeAll()
		PlaybackTeardown.stop(nativePlayer)
		nativeAudio = []
		nativeText = []
	}

	private func armNativeTimeout() {
		nativeTimeout?.cancel()
		guard intent.canPlay, !sharedPausePending else { return }
		let timeout = UInt64(max(20, cacheSeconds + StallTracker.startupGraceSeconds) * 1_000_000_000)
		nativeTimeout = Task { [weak self] in
			do { try await Task.sleep(nanoseconds: timeout) } catch { return }
			guard let self, !Task.isCancelled, self.intent.canPlay, self.usesNative,
				self.nativePlayer.timeControlStatus != .playing else { return }
			self.fallbackToVLC()
		}
	}

	private func fallbackToVLC() {
		guard usesNative, !closing else { return }
		retryTask?.cancel()
		retryTask = nil
		#if os(iOS)
		let retryVideo = !isRelayingVideo && nativePlayer.isExternalPlaybackActive
		#endif
		let time = sharedPlaybackTime
		if !live, time.isFinite, time > 0 { fallbackTime = time }
		stopNative()
		#if os(iOS)
		videoRelay?.stop()
		videoRelay = nil
		#endif
		usesNative = false
		// Compatibility fallback is a fresh backend, not a retry of the failed native open.
		health.reset()
		restartTrackSelection()
		failed = !intent.canPlay
		say(L("compatibility_playback"), 2)
		_ = activateAudio()
		open()
		#if os(iOS)
		if retryVideo { prepareAirPlay() }
		#endif
	}

	private func nativeChoices(_ group: AVMediaSelectionGroup?) -> [TrackChoice] {
		guard let group else { return [] }
		return group.options.map { TrackChoice(name: $0.displayName, option: $0, group: group) }
	}

	private func selectedNativeTracks(_ choices: [TrackChoice]) -> [TrackChoice] {
		choices.map { choice in
			var result = choice
			if let group = choice.group {
				result.selected = nativePlayer.currentItem?.currentMediaSelection.selectedMediaOption(in: group) == choice.option
			}
			return result
		}
	}

	private func chooseTrack(_ choice: TrackChoice) {
		if usesNative, let group = choice.group { nativePlayer.currentItem?.select(choice.option, in: group) }
		else { choice.track?.isSelectedExclusively = true }
	}

	private func announceNativeRoute() {
		#if !os(visionOS)
		guard usesNative, !closing else { return }
		say(nativePlayer.isExternalPlaybackActive ? L("airplay_video") : L("airplay_video_stopped"), 2)
		#endif
	}

	// MARK: VLC events

	nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
		Task { @MainActor in
			if !self.usesNative && !self.preparingVideo && self.openingTask == nil && self.player.state == newState { self.stateChanged(newState) }
		}
	}

	nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
		Task { @MainActor in if !self.usesNative && !self.preparingVideo { self.bufferingChanged(progress) } }
	}

	private func stateChanged(_ s: VLCMediaPlayerState) {
		guard !closing else { return }
		if s == .playing { health.playing() }
		if s == .playing {
			if !usesNative, let file = pendingSubtitle {
				_ = player.addPlaybackSlave(file, type: .subtitle, enforce: true)
				pendingSubtitle = nil
			}
			if !usesNative, let time = fallbackTime, player.isSeekable {
				player.time = VLCTime(int: Int32(min(Double(Int32.max), time * 1000)))
				fallbackTime = nil
			}
			let becameReady = !hasPlayed
			hasPlayed = true
			failed = false
			if sharedPausePending { performSharedPause(temporary: sharedPauseTemporary) }
			if becameReady { sharePlayback?.reapply() }
		}
		if s == .playing && !intent.canPlay {
			if usesNative { nativePlayer.pause() } else { player.pause() }
			return
		}
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
			if recover(grow: true, reason: "player error") { return }
			say(L("play_failed", VLCLibrary.currentErrorMessage ?? ""), 1)
			failed = true
		case .stopped:
			guard intent.canPlay else { return }
			// A live stream that ends was dropped by the server: reconnect, as the desktop does.
			// Casting stops the player on purpose and announces it, so this is not a drop.
			if retryTask != nil || casting != nil || (live && recover(grow: false, reason: "stream stopped")) { return }
			say(L("stream_ended"), 1)
			failed = true
		default:
			break
		}
	}

	/// Buffering is announced here; whether it is a stall is the health tick's call — the
	/// cushion grows only when a restart actually happens, like the desktop, not on every
	/// dip. A Dispatcharr channel never grows: it restreams from its own server-side buffer.
	private func bufferingChanged(_ progress: Float) {
		// Before the first frame this follows "Connecting…", as on Android: a channel
		// stuck buffering is said out loud instead of spinning silently.
		guard !closing else { return }
		if progress < 1 && !buffering {
			buffering = true
			say(L("buffering"), 3)
		} else if progress >= 1 {
			let recovered = buffering
			buffering = false
			if recovered { sharePlayback?.reapply() }
		}
	}

	/// Schedules a reopen of the current stream inside the reconnect budget, for every
	/// kind of playback; false when this stream gets none (paused, casting, relaying).
	/// [grow] is set when the stall earns a bigger cushion, as a desktop stall does; when
	/// the budget is spent the channel is declared lost instead of retrying forever.
	@discardableResult
	private func recover(grow: Bool, reason: String) -> Bool {
		guard intent.canPlay, casting == nil, !isRelayingVideo else { return false }
		if retryTask != nil { return true }
		// Only a live Dispatcharr channel is exempt: its archive streams are ordinary
		// files and keep the extra second, as on the desktop.
		if grow, !(live && channel?.isDispatcharr == true) { stalls += 1 }
		reopened = true
		Self.playbackLog.notice("Reconnect: \(reason, privacy: .public); native=\(self.usesNative); cache=\(self.cacheSeconds)")
		guard let delay = reconnect.next() else { giveUp(); return true }
		// A film or catch-up resumes where it stopped. Take the position now, while the
		// player still holds it: by the time the reopen fires, an errored or stopped
		// player may already report 0, and the film would skip back to the start.
		if !live { let time = sharedPlaybackTime; if time > 0 { fallbackTime = time } }
		say(L("reconnecting"), 2)
		retryTask = Task {
			try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
			guard !Task.isCancelled, !closing, intent.canPlay, !preparingVideo, !isRelayingVideo else { return }
			retryTask = nil
			open()
		}
		return true
	}

	/// The budget is spent, or the channel never played at all: the desktop declares it
	/// lost and stops, rather than leaving a silent spinner up.
	private func giveUp() {
		guard !failed else { return }
		retryTask?.cancel()
		retryTask = nil
		failed = true
		if usesNative { nativePlayer.pause() } else { PlaybackTeardown.stop(player) }
		isPlaying = false
		nowPlayingInfo()
		say(L("stream_lost"), 1)
	}

	/// Once a second, the desktop's playback-health rules run over whichever player is
	/// active (StallTracker): prolonged buffering, a frozen picture and repeated short
	/// stalls reopen the stream with a bigger cushion; a channel that produces nothing
	/// restarts, then is given up on. SharePlay sessions keep their own recovery.
	private func healthTick() {
		// Once failed, the verdicts are spent: a later "Stream lost" must not overwrite
		// the real failure (a busy provider, a teardown timeout). While casting or
		// relaying, the receiver owns playback, as with Android's remote device check.
		guard !closing, !failed, intent.canPlay, sharePlayback == nil, retryTask == nil, openingTask == nil, !preparingVideo, casting == nil, !isRelayingVideo else { return }
		let playingNow = usesNative ? nativePlayer.timeControlStatus == .playing : player.state == .playing
		var frozen = 0.0
		if playingNow {
			// Preserve invalid timestamps: sharedPlaybackTime clamps them for UI and SharePlay.
			let position = usesNative ? nativePlayer.currentTime().seconds : Double(player.time.intValue) / 1000
			if !usesNative, let stats = player.media?.statistics {
				frozen = progress.sample(position: position,
					audio: .init(decoded: stats.decodedAudio, output: stats.playedAudioBuffers),
					video: videoOff ? nil : .init(decoded: stats.decodedVideo, output: stats.displayedPictures))
			} else { frozen = progress.sample(position: position) }
		} else { progress.reset() }
		// VLCKit 4 has no buffering state: a stall after play is the buffering flag,
		// and before play it is the opening state.
		let waiting = usesNative ? nativePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
			: buffering || player.state == .opening
		switch health.tick(buffering: waiting, frozen: frozen) {
		case .none: break
		case .restart: recover(grow: false, reason: "no media")
		case .restartGrown: recover(grow: true, reason: "playback stalled; waiting=\(waiting), frozen=\(frozen)")
		case .giveUp: giveUp()
		}
	}

	// MARK: controls

	func togglePause() {
		if intent.canPlay && !failed { pause() } else { resume() }
	}

	func pause() {
		guard !closing else { return }
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
		openingTask?.cancel()
		openingTask = nil
		retryTask = nil
		player.pause()
		if usesNative { nativePlayer.pause(); nativeTimeout?.cancel() }
		#if os(iOS)
		if !live, !preparingVideo { videoRelay?.player.pause() }
		#endif
		isPlaying = false
		nowPlayingInfo()
	}

	func resume() {
		guard !closing else { return }
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
		progress.reset()
		if !isPlaying {
			health.prepared()
			if usesNative ? nativePlayer.timeControlStatus == .playing : player.state == .playing { health.playing() }
		}
		UIApplication.shared.isIdleTimerDisabled = UIApplication.shared.applicationState == .active
		#if os(iOS)
		if let relay = videoRelay {
			// Conversion already owns the provider while its first manifest is being written.
			if relay.url == nil { return }
			PlaybackTeardown.play(relay.player)
		}
		#endif
		if usesNative {
			if failed || nativePlayer.currentItem == nil {
				reconnect.reset()
				health.reset()
				stalls = 0
				reopened = false
				failed = false
				open()
			}
			else { nativePlayer.play(); armNativeTimeout() }
			return
		}
		if failed || player.state == .stopped || player.state == .stopping || player.state == .error {
			// Retry after a failure: a fresh start — quick start, saved buffer, full budget.
			retryTask?.cancel()
			retryTask = nil
			reconnect.reset()
			health.reset()
			stalls = 0
			reopened = false
			failed = false
			open()
			return
		}
		PlaybackTeardown.play(player)
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

	// MARK: audio tracks

	struct TrackChoice {
		let name: String
		var track: VLCMediaPlayer.Track?
		var option: AVMediaSelectionOption?
		var group: AVMediaSelectionGroup?
		var selected = false
		var isSelected: Bool { track?.isSelected ?? selected }
	}

	func audioTracks() -> [TrackChoice] {
		#if os(iOS)
		if let relay = videoRelay { return named(relay.player.audioTracks) }
		#endif
		return usesNative ? selectedNativeTracks(nativeAudio) : named(player.audioTracks)
	}
	func textTracks() -> [TrackChoice] {
		#if os(iOS)
		if let relay = videoRelay { return named(relay.player.textTracks) }
		#endif
		return usesNative ? selectedNativeTracks(nativeText) : named(player.textTracks)
	}

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

	private func restartTrackSelection() {
		trackTimer?.invalidate()
		guard !isRelayingVideo else { autoTrackDone = true; return }
		autoTrackDone = false
		autoTrackTries = 0
		trackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoTrack() } }
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
			describesVideo: audio.map { $0.option?.hasMediaCharacteristic(.describesVideoForAccessibility) ?? false },
			remembered: prefs.rememberedTrack(request.channelKey),
			preferAd: prefs.preferAudioDescription,
			keywords: prefs.audioKeywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		)
		if idx >= 0 {
			if !audio[idx].isSelected { chooseTrack(audio[idx]) }
			autoTrackDone = true
		} else if autoTrackTries >= 6 {
			autoTrackDone = true
		}
	}

	func selectAudio(_ c: TrackChoice) {
		chooseTrack(c)
		autoTrackDone = true
		// Remembered per channel, ahead of every other rule, like the desktop app.
		if !request.channelKey.isEmpty { prefs.rememberTrack(request.channelKey, c.name) }
		say(L("audio_track_set", c.name), 2)
	}

	// MARK: subtitles

	func selectSubtitle(_ c: TrackChoice?) {
		selectedSubtitleName = c?.name
		if let c {
			chooseTrack(c)
			say(L("subtitles_set", c.name), 2)
		} else {
			if usesNative, let group = nativeText.first?.group { nativePlayer.currentItem?.select(nil, in: group) }
			player.deselectAllTextTracks()
			#if os(iOS)
			videoRelay?.player.deselectAllTextTracks()
			#endif
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
		// External subtitle files use VLC's existing renderer and spoken-cue path.
		loadedSubtitleFile = copy
		selectedSubtitleName = picked.lastPathComponent
		if usesNative && !isRelayingVideo { fallbackToVLC() }
		#if os(iOS)
		let subtitlePlayer = videoRelay?.player ?? player
		#else
		let subtitlePlayer = player
		#endif
		if subtitlePlayer.isPlaying { _ = subtitlePlayer.addPlaybackSlave(copy, type: .subtitle, enforce: true) }
		else { pendingSubtitle = copy }
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
		let off = !textTracks().contains { $0.isSelected }
		// The subtitle delay is in microseconds; a positive delay shows cues later.
		let ms = Int64(sharedPlaybackTime * 1000) - Int64(player.currentVideoSubTitleDelay / 1000)
		let index = off || ms < 0 ? nil : SubtitleCues.active(cues, ms)
		guard index != cueIndex else { return }
		cueIndex = index
		let text = index.map { cues[$0].text } ?? ""
		subtitle = text
		if !text.isEmpty && prefs.speakSubtitles && isPlaying { announce(text) }
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
		guard !closing else { return }
		if let r { prepareVideoRelay(renderer: r); return }
		if sharePlayback != nil { SharePlayCenter.shared.leave() }
		let time = sharedPlaybackTime
		castPreparation?.cancel()
		preparingVideo = true
		stopNative()
		PlaybackTeardown.stop(player)
		_ = player.setRendererItem(nil)
		videoRelay?.stop()
		videoRelay = nil
		casting = nil
		usesNative = PlaybackBackend.preferred(for: request.url) == .native
		if !live && time > 0 { fallbackTime = time }
		preparingVideo = false
		open()
		say(L("cast_stopped"), 2)
	}

	/// The route picker keeps the same AVPlayer while an incompatible source is converted.
	func prepareAirPlay() {
		guard !usesNative || casting != nil else { return }
		prepareVideoRelay(renderer: nil)
	}

	/// Picking an AirPlay device starts conversion automatically; no Prepare step.
	/// Compatible streams already play natively, and audio-only routes need no video.
	func airPlayDevicePicked() {
		guard !usesNative else { return }
		guard AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay }) else { return }
		prepareAirPlay()
	}

	private func prepareVideoRelay(renderer: Renderer?) {
		guard !closing, !preparingVideo else { return }
		if sharePlayback != nil { SharePlayCenter.shared.leave() }
		retryTask?.cancel()
		retryTask = nil
		intent.play()
		isPaused = false
		guard activateAudio() else { return }
		if videoRelay?.url != nil { playRelay(renderer: renderer); return }
		let position = live ? 0 : sharedPlaybackTime
		preparingVideo = true
		casting = renderer?.name
		say(L("preparing_video_cast"), 2)
		castPreparation?.cancel()
		castPreparation = Task { [weak self] in
			guard let self else { return }
			if self.usesNative || self.player.videoTracks.isEmpty {
				self.stopNative()
				self.usesNative = false
				PlaybackTeardown.stop(self.player)
				_ = self.player.setRendererItem(nil)
				self.open()
			}
			let deadline = ProcessInfo.processInfo.systemUptime + 15
			while self.player.videoTracks.isEmpty || self.player.audioTracks.isEmpty {
				guard !Task.isCancelled, !self.closing else { return }
				if ProcessInfo.processInfo.systemUptime >= deadline { break }
				do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
			}
			guard !Task.isCancelled, !self.closing else { return }
			guard let video = self.player.videoTracks.first(where: { $0.isSelected }) ?? self.player.videoTracks.first else {
				self.relayFailed(); return
			}
			self.hasPlayed = true
			self.autoTrackDone = false
			self.autoTrackTries = 0
			self.autoTrack()
			let audio = self.player.audioTracks.first(where: { $0.isSelected }) ?? self.player.audioTracks.first
			let subtitles = self.named(self.player.textTracks)
			if let name = self.selectedSubtitleName {
				let index = AudioTracks.choose(names: subtitles.map(\.name), describesVideo: subtitles.map { _ in false }, remembered: name, preferAd: false, keywords: [])
				if index >= 0 { subtitles[index].track?.isSelectedExclusively = true }
			}
			let subtitleID = self.player.textTracks.first(where: { $0.isSelected })?.trackId
			let tracks = [video.trackId] + (audio.map { [$0.trackId] } ?? [])
			// Reserve the relay before teardown so Resume cannot reopen the direct source during handoff.
			let relay = VideoRelay()
			self.videoRelay = relay
			PlaybackTeardown.stop(self.player)
			guard await PlaybackTeardown.ready(), !Task.isCancelled, !self.closing else {
				if !Task.isCancelled, !self.closing { self.relayFailed() }
				return
			}
			// Some single-session providers retain the old session briefly after its connection closes.
			if !self.localFile {
				do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
			}
			guard !Task.isCancelled, !self.closing else { return }
			self.relayStartTime = position
			relay.onFailure = { [weak self] in self?.relayFailed() }
			relay.start(source: self.request.url, tracks: tracks, seconds: position, subtitleID: subtitleID,
				subtitleFile: subtitleID == nil ? nil : self.loadedSubtitleFile, live: self.live) { [weak self, weak relay] result in
				guard let self, let relay, self.videoRelay === relay, !self.closing else { return }
				self.preparingVideo = false
				switch result {
				case .success:
					self.playRelay(renderer: renderer)
					if !self.intent.canPlay, !self.live { relay.player.pause() }
				case .failure: self.relayFailed()
				}
			}
		}
	}

	private func playRelay(renderer: Renderer?) {
		preparingVideo = true
		stopNative()
		PlaybackTeardown.stop(player)
		_ = player.setRendererItem(renderer?.item)
		casting = renderer?.name
		usesNative = renderer == nil
		preparingVideo = false
		restartTrackSelection()
		guard activateAudio() else { return }
		open()
		say(renderer.map { L("casting_to", $0.name) } ?? L("video_cast_ready"), 2)
	}

	private func relayFailed() {
		guard !closing else { return }
		preparingVideo = true
		stopNative()
		PlaybackTeardown.stop(player)
		_ = player.setRendererItem(nil)
		videoRelay?.stop()
		videoRelay = nil
		usesNative = false
		casting = nil
		preparingVideo = false
		open()
		say(L("video_cast_failed"), 1)
	}
	#endif

	// MARK: background and lock screen

	/// In the background the video is switched off and the sound keeps playing; back in the
	/// app, the picture returns.
	func scene(_ phase: ScenePhase) {
		UIApplication.shared.isIdleTimerDisabled = phase == .active && !isPaused
		if phase == .active { progress.reset() }
		nativeVideoAttached = phase != .background
		if usesNative { return }
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
			#if os(iOS)
			try session.setCategory(.playback, mode: .moviePlayback, policy: usesNative ? .longFormVideo : .longFormAudio)
			#else
			try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
			#endif
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
				let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
			Task { @MainActor in
				guard let self else { return }
				self.announceAirPlayRoute(reason)
				guard reason == .oldDeviceUnavailable else { return }
				self.sharePlayback?.suspend()
				self.pauseLocally()
			}
		})
	}

	/// Announce audio routing independently of native external-video playback.
	private func announceAirPlayRoute(_ reason: AVAudioSession.RouteChangeReason) {
		guard reason == .newDeviceAvailable || reason == .routeConfigurationChange || reason == .oldDeviceUnavailable else { return }
		let route = AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }?.portName
		guard route != airPlayRoute else { return }
		airPlayRoute = route
		say(route.map { L("sound_on", $0) } ?? L("airplay_audio_stopped"), 2)
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
			if usesNative { nativePlayer.pause(); nativeTimeout?.cancel() }
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

	// MARK: SharePlay's native custom-player adapter

	var isSharingPlayback: Bool { sharePlayback != nil }
	var sharedPlaybackTime: Double {
		let time = usesNative ? nativePlayer.currentTime().seconds : Double(player.time.intValue) / 1000
		return time.isFinite ? max(0, time) + (isRelayingVideo && !live ? relayStartTime : 0) : 0
	}
	var sharedPlaybackRate: Float { isPaused ? 0 : 1 }
	var sharedPlaybackReady: Bool {
		guard hasPlayed, !buffering, !failed, !closing, retryTask == nil else { return false }
		if usesNative {
			guard nativePlayer.currentItem?.status == .readyToPlay else { return false }
		} else if player.state != .playing && player.state != .paused { return false }
		if let target = sharedSeekTarget {
			guard abs(sharedPlaybackTime - target) < 0.5 else { return false }
			sharedSeekTarget = nil
		}
		return true
	}
	var sharedPlaybackSeekable: Bool { !live && !isRelayingVideo && (usesNative ? nativePlayer.currentItem?.seekableTimeRanges.isEmpty == false : player.isSeekable) }
	var sharedPlaybackFailed: Bool { failed || closing }

	func joinSharePlay(_ session: GroupSession<WatchTVActivity>, identifier: String) {
		leaveSharePlay()
		player.rate = 1
		if usesNative, isPlaying { nativePlayer.rate = 1 }
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
		// Let the engine finish opening before pausing, so it can report readiness to SharePlay.
		if hasPlayed {
			if temporary {
				player.pause()
				if usesNative { nativePlayer.pause(); nativeTimeout?.cancel() }
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
		if usesNative { nativePlayer.rate = rate }
	}

	func performSharedSeek(seconds: Double) {
		guard sharedPlaybackSeekable, seconds.isFinite else { return }
		let target = min(Double(Int32.max) / 1000, max(0, seconds))
		guard abs(sharedPlaybackTime - target) > 0.2 else { return }
		sharedSeekTarget = target
		if usesNative { nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) }
		else { player.time = VLCTime(int: Int32(target * 1000)) }
	}

	func recoverSharedPlayback() {
		guard !closing, sharePlayback != nil else { return }
		intent.play()
		guard intent.canPlay, activateAudio() else { return }
		retryTask?.cancel()
		retryTask = nil
		reconnect.reset()
		reopened = true
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
			MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(usesNative ? nativePlayer.rate : player.rate) : 0.0,
		]
	}
}
