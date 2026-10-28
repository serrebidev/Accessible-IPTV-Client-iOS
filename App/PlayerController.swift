import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit
import SwiftVLC
import AetherEngine
import IPTVCore
import GroupActivities
import OSLog

/// Native playback and AirPlay for compatible media; VLC handles raw TS and other IPTV formats.
@MainActor
final class PlayerController: NSObject, ObservableObject {
	@Published var status = ""
	@Published var isPlaying = false
	@Published var failed = false
	@Published var nowPlaying = ""
	/// The guide programme on now, for Siri's on-screen context.
	@Published var currentProgramme: Programme?
	@Published var subtitle = ""
	@Published var casting: String?
	@Published var fullscreen = false
	@Published private(set) var isPaused = false
	@Published private(set) var usesNative: Bool
	@Published private(set) var usesAether: Bool
	@Published private(set) var nativeVideoAttached = true
	/// Picture in Picture is running, on either engine that supports it.
	@Published private(set) var pipActive = false
	/// An AetherEngine session has a PiP source, so the PiP button can be offered.
	@Published private(set) var aetherPiPReady = false
	let nativePlayer = AVPlayer()
	/// The AetherEngine sample-buffer PiP controller, rebuilt for each session's source.
	private var pipController: AVPictureInPictureController?
	private let pipBridge = PiPBridge()
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

	let player = Player(instance: .app)
	private var vlcEvents: Task<Void, Never>?
	private var subtitleText: Task<Void, Never>?
	/// Transport streams play through AetherEngine instead of libVLC (PlaybackBackend).
	let aether: AetherEngine
	private var aetherEvents: Set<AnyCancellable> = []
	private var aetherLoad: Task<Void, Never>?
	/// An AetherEngine failure before the first frame demotes this screen to libVLC,
	/// the same compatibility fallback native playback has; it never demotes twice.
	private var aetherDemoted = false
	let request: PlayRequest
	private let model = AppModel.shared
	private var prefs: Prefs { model.prefs }
	/// The Settings opt-in for subtitles, read by the player screen for its system menu.
	var subtitlesEnabled: Bool { prefs.subtitlesEnabled }
	/// Subtitles show only when the user opted in, or picked a track or a subtitle file
	/// in this session (selectedSubtitleName is that pick; choosing Off clears it).
	private var subtitlesAllowed: Bool { prefs.subtitlesEnabled || selectedSubtitleName != nil }
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
	/// When the current buffering spell began, and the last libVLC counters, for the playback log.
	private var bufferingSince: Double?
	private var lastStats: (stats: PlaybackStats, at: Double)?
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
	private var discoverers: [RendererDiscoverer] = []
	private var discovery: [Task<Void, Never>] = []
	private var found: [RendererItem] = []
	/// The cast receiver VLC plays to, applied with each open.
	private var castTarget: RendererItem?
	private var videoRelay: VideoRelay?
	private var castPreparation: Task<Void, Never>?
	#endif

	init(request: PlayRequest) {
		self.request = request
		usesNative = PlaybackBackend.preferred(for: request.url) == .native
		usesAether = PlaybackBackend.preferred(for: request.url) == .aether
		// The engine's init installs its FFmpeg log bridge and observers; it declares
		// throws but has no failure a host can act on (its own examples treat it the same).
		aether = try! AetherEngine()
		let ch = request.channel
		channel = ch
		live = !request.catchup && ch?.isLive == true
		localFile = request.url.hasPrefix("file:")
		super.init()
		// Off until openNative applies the user's subtitle opt-in: the system's caption
		// preferences must never turn subtitles on by themselves.
		nativePlayer.appliesMediaSelectionCriteriaAutomatically = false
		pipBridge.owner = self
	}

	// MARK: picture in picture

	/// A Picture in Picture button can be offered: an AetherEngine session whose PiP
	/// source exists. The native player's PiP needs no button — AVKit starts it itself
	/// when the app backgrounds — and libVLC has no PiP at all.
	var pipStartable: Bool { usesAether && aetherPiPReady }

	/// Starts PiP on the AetherEngine path (the button, or the app backgrounding).
	func startPiP() {
		guard let pipController, pipController.isPictureInPicturePossible, !pipActive else { return }
		pipController.startPictureInPicture()
	}

	private func rebuildPiP(_ source: SoftwarePiPSource?) {
		pipController?.stopPictureInPicture()
		pipController = nil
		aetherPiPReady = false
		guard usesAether, let source, AVPictureInPictureController.isPictureInPictureSupported() else { return }
		let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: pipBridge))
		controller.delegate = pipBridge
		pipController = controller
		aetherPiPReady = true
	}

	func pipStarted() {
		pipActive = true
		if usesAether { aether.pictureInPictureActive = true }
	}

	func pipStopped() {
		pipActive = false
		if usesAether { aether.pictureInPictureActive = false }
	}

	/// PiP's own restore affordance: bring the full player screen back.
	func restoreFromPiP() { model.playerPresented = true }

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
		observeVLC()
		observeAether()
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
			for service in RendererDiscoverer.availableServices(instance: .app) {
				guard let d = try? RendererDiscoverer(name: service.name, instance: .app) else { continue }
				let events = d.events
				discovery.append(Task { [weak self] in
					for await event in events {
						guard let self else { return }
						if let item = event.itemAdded { self.found.append(item) }
						if let item = event.itemDeleted { self.found.removeAll { $0 == item } }
					}
				})
				if (try? d.start()) != nil { discoverers.append(d) }
			}
		}
		#endif
	}

	/// libVLC's events arrive on the main actor. Text subtitles are captured as text, shown and
	/// spoken by the app (closed captions, teletext and subtitle files alike).
	private func observeVLC() {
		let events = player.events
		vlcEvents = Task { [weak self] in
			for await event in events {
				guard let self else { return }
				switch event {
				case .stateChanged(let state):
					if !self.usesNative && !self.usesAether && !self.preparingVideo && self.openingTask == nil && self.player.state == state { self.stateChanged(state) }
				case .bufferingProgress(let fill):
					if !self.usesNative && !self.usesAether && !self.preparingVideo { self.vlcBuffering(fill) }
				default: break
				}
			}
		}
		guard let captions = try? player.textSubtitleStream() else { return }
		subtitleText = Task { [weak self] in
			for await snapshot in captions {
				guard let self else { return }
				self.captionChanged(snapshot.text)
			}
		}
	}

	/// AetherEngine's published state, folded into the same handlers the other backends
	/// feed. The engine's own reconnect rides a drop first; a live reset is its word that
	/// the session cannot be revived in place, so it joins the app's reconnect budget.
	private func observeAether() {
		aether.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
			guard let self, self.usesAether, !self.closing else { return }
			switch state {
			case .playing:
				self.bufferingChanged(1)
				self.stateChanged(.playing)
			case .paused:
				self.isPlaying = false
				self.nowPlayingInfo()
			case .ended:
				self.stateChanged(.stopped)
			case .error(let message):
				self.aetherError(message)
			default: break
			}
		}.store(in: &aetherEvents)
		aether.$playbackPhase.receive(on: DispatchQueue.main).sink { [weak self] phase in
			guard let self, self.usesAether, !self.closing else { return }
			switch phase {
			case .rebuffering, .stalled: self.bufferingChanged(0)
			default: break
			}
		}.store(in: &aetherEvents)
		aether.liveSourceReset.receive(on: DispatchQueue.main).sink { [weak self] _ in
			guard let self, self.usesAether, !self.closing else { return }
			self.note("aether live reset")
			_ = self.recover(grow: false, reason: "aether live reset")
		}.store(in: &aetherEvents)
		aether.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] cues in
			guard let self, self.usesAether, !self.closing else { return }
			let now = self.aether.clock.sourceTime
			guard let cue = cues.last(where: { $0.startTime <= now && now < $0.endTime }) else { return }
			switch cue.body {
			case .text(let text): self.captionChanged(text)
			case .richText(let runs): self.captionChanged(runs.map(\.text).joined())
			case .image: break
			}
		}.store(in: &aetherEvents)
		aether.$softwarePiPSource.receive(on: DispatchQueue.main).sink { [weak self] source in
			guard let self, !self.closing else { return }
			self.rebuildPiP(source)
		}.store(in: &aetherEvents)
		aether.$subtitleTracks.receive(on: DispatchQueue.main).sink { [weak self] tracks in
			guard let self, self.usesAether, !self.closing, !tracks.isEmpty,
				self.aether.activeSubtitleTrackIndex == nil, self.cues.isEmpty, self.subtitlesAllowed else { return }
			// Cues flow only once a track is selected, as they did from libVLC's stream.
			// Subtitles are opt-in, so the first track is picked only when the user
			// turned subtitles on or already picked one this session.
			self.aether.selectSubtitleTrack(index: tracks[0].id)
		}.store(in: &aetherEvents)
	}

	/// The engine published a terminal failure. Before the first frame that means this
	/// source is not one it can carry here: demote to libVLC once, like the native
	/// fallback. After playback, the ordinary reconnect loop owns it.
	private func aetherError(_ message: String) {
		note("aether error: \(message)")
		if !hasPlayed && !aetherDemoted {
			aetherDemoted = true
			usesAether = false
			aetherLoad?.cancel()
			aether.stop()
			health.reset()
			restartTrackSelection()
			failed = !intent.canPlay
			say(L("compatibility_playback"), 2)
			_ = activateAudio()
			open()
			return
		}
		stateChanged(.error)
	}

	func close() {
		guard !closing else { return }
		closing = true
		note("closed")
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
		aetherLoad?.cancel()
		pipController?.stopPictureInPicture()
		pipController = nil
		aetherPiPReady = false
		if usesAether { aether.pictureInPictureActive = false }
		aether.stop()
		aetherEvents.removeAll()
		PlaybackTeardown.stop(player)
		vlcEvents?.cancel()
		subtitleText?.cancel()
		MediaConnection.shared.release(connectionID) { await PlaybackTeardown.finished() }
		#if os(iOS)
		discovery.forEach { $0.cancel() }
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
			: Cushion.openSeconds(base: prefs.bufferSeconds, max: prefs.maxBufferSeconds, stalls: stalls, reopened: reopened,
				dispatcharr: channel?.isDispatcharr == true)
		health.prepared(caching: cacheSeconds)
		bufferingSince = nil
		lastStats = nil
		note("open \(usesNative ? "native" : usesAether ? "AetherEngine" : "libVLC"), cache \(cacheSeconds) s\(reopened ? ", reopen" : "")")
		if usesNative { openNative(); return }
		if usesAether { openAether(); return }
		let (plain, headers) = M3U.splitHeaders(playbackURL)
		guard let url = URL(string: plain) ?? (try? Net.url(plain)), let media = try? Media(url: url) else {
			say(L("play_failed", plain), 1)
			failed = true
			return
		}
		// libVLC 4 has no public cookie API: a playlist's Cookie header is not sent.
		media.setHTTPUserAgent(headers["User-Agent"] ?? Net.userAgent)
		if let ref = headers["Referer"] { media.setHTTPReferrer(ref) }
		if live {
			// Live: drop late frames so playback stays at real time instead of drifting behind.
			media.addOption(":clock-jitter=1500")
		} else {
			// VOD, catch-up and files open with the same full caching value as the desktop.
			media.addOption(":clock-jitter=0")
			media.addOption(":clock-synchro=0")
			media.addOption(":drop-late-frames=0")
			media.addOption(":skip-frames=0")
		}
		StreamOptions.network(url, live: live, cacheMs: Int(cacheSeconds * 1000)).forEach { media.addOption($0) }
		media.addOption(":rtsp-tcp")
		hasPlayed = false
		buffering = false
		#if os(iOS)
		PlaybackTeardown.play(player, media, renderer: castTarget)
		#else
		PlaybackTeardown.play(player, media)
		#endif
	}

	/// A transport stream through AetherEngine: the saved cushion is held on the live
	/// edge (the cushion a rebuffer refills before resuming), where libVLC's network
	/// cache could only be set once at the open and read bursts as starvation.
	private func openAether() {
		let (plain, headers) = M3U.splitHeaders(playbackURL)
		guard let url = URL(string: plain) ?? (try? Net.url(plain)) else {
			say(L("play_failed", plain), 1)
			failed = true
			return
		}
		var httpHeaders = ["User-Agent": headers["User-Agent"] ?? Net.userAgent]
		if let ref = headers["Referer"] { httpHeaders["Referer"] = ref }
		// Join like the other platforms: start on the first keyframes, never buy the
		// buffer with waiting. In this engine liveEdgeCushionSeconds is a join gate —
		// a join holds until that much media stands behind the edge, at 1x on a raw
		// TS — and .standard's own holdback floor is 18 s, so passing the saved buffer
		// (25 s) made every channel change wait ~20 s before the first frame. fastZap
		// collapses the holdback to the source's keyframe cadence. The probe budgets
		// are also tightened from the engine defaults (50 MB / 60 s) so stream-info
		// probing cannot read a slow source for tens of seconds before a load returns.
		let options = LoadOptions(
			httpHeaders: httpHeaders,
			isLive: live,
			liveJoinProfile: live ? .fastZap : .standard,
			probesize: 10_000_000,
			maxAnalyzeDuration: 10_000_000
		)
		hasPlayed = false
		buffering = false
		aetherLoad?.cancel()
		aetherLoad = Task { [weak self] in
			guard let self else { return }
			do {
				_ = try await self.aether.load(url: url, options: options)
				if self.intent.canPlay { self.aether.play() }
			} catch is CancellationError {
				// A newer load or a stop superseded this one; the successor owns the session.
			} catch {
				// The same failure arrives as .error on the state publisher; it is handled there.
			}
		}
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
		// After a stall, live HLS skips ahead to its distance from the live edge instead of drifting behind.
		item.automaticallyPreservesTimeOffsetFromLive = live
		// Subtitles are opt-in: with the setting off, the player must not apply the
		// system's caption preferences (on iOS 27 those would also switch on generated
		// subtitles unasked). With it on, the system criteria apply, so the user's
		// caption language and generated-subtitle choices reach playback.
		nativePlayer.appliesMediaSelectionCriteriaAutomatically = prefs.subtitlesEnabled
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
		note("native player failed: compatibility playback")
		say(L("compatibility_playback"), 2)
		_ = activateAudio()
		open()
		#if os(iOS)
		if retryVideo { prepareAirPlay() }
		#endif
	}

	private func nativeChoices(_ group: AVMediaSelectionGroup?) -> [TrackChoice] {
		guard let group else { return [] }
		return group.options.map { option in
			var name = option.displayName
			// AVKit's own menu names OS-generated and translated options itself; a
			// custom list derives the suffix from the option's media characteristics.
			if #available(iOS 26.0, tvOS 26.0, visionOS 26.0, *), option.hasMediaCharacteristic(.machineGenerated) {
				name = L("subtitle_generated", name)
			} else if option.hasMediaCharacteristic(.languageTranslation) {
				name = L("subtitle_translated", name)
			}
			return TrackChoice(name: name, option: option, group: group)
		}
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
		if let id = choice.aetherID {
			if choice.aetherAudio { aether.selectAudioTrack(index: id) } else { aether.selectSubtitleTrack(index: id) }
		}
		else if usesNative, let group = choice.group { nativePlayer.currentItem?.select(choice.option, in: group) }
		else if let track = choice.track, let owner = choice.owner {
			if track.type == .audio { owner.selectedAudioTrack = track } else { owner.selectedSubtitleTrack = track }
		}
	}

	private func announceNativeRoute() {
		#if !os(visionOS)
		guard usesNative, !closing else { return }
		say(nativePlayer.isExternalPlaybackActive ? L("airplay_video") : L("airplay_video_stopped"), 2)
		#endif
	}

	// MARK: VLC events

	/// libVLC's buffer fill, 0 to 1; VLC reports rebuffering only through it once playing.
	func vlcBuffering(_ fill: Float) {
		bufferingChanged(fill)
	}

	private func stateChanged(_ s: PlayerState) {
		guard !closing else { return }
		if s == .playing { health.playing() }
		if s == .playing {
			if !usesNative && !usesAether, let file = pendingSubtitle {
				try? player.addExternalTrack(from: file, type: .subtitle, select: true)
				pendingSubtitle = nil
			}
			if !usesNative && !usesAether, let time = fallbackTime, player.isSeekable {
				try? player.seek(to: .milliseconds(Int64(time * 1000)))
				fallbackTime = nil
			}
			if usesAether, let time = fallbackTime, !live {
				fallbackTime = nil
				Task { [weak self] in await self?.aether.seek(to: time) }
			}
			let becameReady = !hasPlayed
			hasPlayed = true
			failed = false
			if sharedPausePending { performSharedPause(temporary: sharedPauseTemporary) }
			if becameReady { sharePlayback?.reapply() }
		}
		if s == .playing && !intent.canPlay {
			if usesNative { nativePlayer.pause() } else if usesAether { aether.pause() } else { player.pause() }
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
			if videoOff && !usesAether { player.setVideoEnabled(false) }
			hasPlayed = true
			failed = false
		case .error:
			if recover(grow: true, reason: "player error") { return }
			say(L("play_failed", request.title), 1)
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
			bufferingSince = ProcessInfo.processInfo.systemUptime
			note(hasPlayed ? "buffering started" : "waiting for the first frame")
			say(L("buffering"), 3)
		} else if progress >= 1 {
			let recovered = buffering
			buffering = false
			if let since = bufferingSince {
				note(String(format: "buffering ended after %.1f s", ProcessInfo.processInfo.systemUptime - since))
				bufferingSince = nil
			}
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
		note("reconnect: \(reason); cache \(cacheSeconds) s")
		guard let delay = reconnect.next() else { note("reconnect budget spent"); giveUp(); return true }
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
		note("gave up: stream lost")
		retryTask?.cancel()
		retryTask = nil
		failed = true
		if usesNative { nativePlayer.pause() } else if usesAether { aether.stop() } else { PlaybackTeardown.stop(player) }
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
		let playingNow = usesNative ? nativePlayer.timeControlStatus == .playing
			: usesAether ? aether.state == .playing : player.state == .playing
		// observeVLC drops a Playing event that arrives before player.state matches it (its
		// stale-event filter), and then nothing marks the channel played: it was restarted at
		// 25 s and given up at 30 s while audibly playing (CI 2026-10-27; KitBoga the same night).
		// The state itself is the truth.
		if playingNow, !usesNative, !hasPlayed {
			note("Playing event missed: taking the player's state")
			stateChanged(.playing)
		}
		var frozen = 0.0
		if playingNow {
			// Preserve invalid timestamps: sharedPlaybackTime clamps them for UI and SharePlay.
			let position = usesNative ? nativePlayer.currentTime().seconds
				: usesAether ? aether.clock.currentTime : vlcSeconds
			if !usesNative && !usesAether, let stats = player.statistics {
				// Read only while playing, as before the playback log: with the read also running
				// during an open, the v0.6.0 tag failed the "reaches Playing" integration tests.
				logStats(stats)
				frozen = progress.sample(position: position,
					audio: .init(decoded: stats.decodedAudio, output: stats.playedAudioBuffers),
					video: videoOff ? nil : .init(decoded: stats.decodedVideo, output: stats.displayedPictures))
			} else { frozen = progress.sample(position: position) }
		} else { progress.reset() }
		// VLC's buffering state exists only before the first frame: a later stall is the buffering flag.
		let waiting = usesNative ? nativePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
			: usesAether ? buffering || aether.state == .loading
			: buffering || player.state == .opening || player.state == .buffering
		switch health.tick(buffering: waiting, frozen: frozen) {
		case .none: break
		case .restart: recover(grow: false, reason: "no media")
		case .restartGrown: recover(grow: true, reason: "playback stalled; waiting=\(waiting), frozen=\(frozen)")
		case .giveUp: note("nothing played within \(Int(StallTracker.firstPlayDeadlineSeconds)) s"); giveUp()
		}
	}

	/// Every 10 s of playback: what arrived and what the decoders did with it, so a stall reads
	/// as either the network (bytes stop) or the player (bytes arrive, frames lost). A buffering
	/// spell shows up as one longer interval whose bytes cover the whole spell.
	private func logStats(_ s: MediaStatistics) {
		var now = PlaybackStats()
		now.readBytes = s.readBytes
		now.inputKbps = s.inputBitrate
		now.corrupted = s.demuxCorrupted
		now.discontinuities = s.demuxDiscontinuity
		now.decodedVideo = s.decodedVideo
		now.shownPictures = s.displayedPictures
		now.latePictures = s.latePictures
		now.lostPictures = s.lostPictures
		now.playedAudio = s.playedAudioBuffers
		now.lostAudio = s.lostAudioBuffers
		let t = ProcessInfo.processInfo.systemUptime
		guard let last = lastStats else { lastStats = (now, t); return }
		guard t - last.at >= 10 else { return }
		note(now.line(since: last.stats, seconds: t - last.at))
		lastStats = (now, t)
	}

	/// One line for the copyable playback log (Settings) and the system log. Never a URL:
	/// stream URLs carry credentials, and an unnamed entry's title is its URL.
	private func note(_ line: String) {
		let name = request.title.contains("://") ? "unnamed channel" : request.title
		PlaybackLog.shared.add("\(name): \(line)")
		Self.playbackLog.notice("\(line, privacy: .public)")
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
		note("paused")
		intent.pause()
		isPaused = true
		UIApplication.shared.isIdleTimerDisabled = false
		retryTask?.cancel()
		openingTask?.cancel()
		openingTask = nil
		retryTask = nil
		player.pause()
		if usesAether { aether.pause() }
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
		note("resumed")
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
		if usesAether {
			var engineError = false
			if case .error = aether.state { engineError = true }
			if failed || engineError || aether.state == .idle || aether.state == .ended {
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
			aether.play()
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
		guard live, let ch = channel else { nowPlaying = request.title; currentProgramme = nil; return }
		let nn = model.library.epg.nowNext(ch)
		currentProgramme = nn.now
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
		var track: Track?
		/// The VLC player the track belongs to: this screen's, or the AirPlay conversion's.
		var owner: Player?
		var option: AVMediaSelectionOption?
		var group: AVMediaSelectionGroup?
		/// An AetherEngine stream index, with whether it came from the audio list.
		var aetherID: Int?
		var aetherAudio = false
		var selected = false
		var isSelected: Bool { track?.isSelected ?? selected }
	}

	func audioTracks() -> [TrackChoice] {
		#if os(iOS)
		if let relay = videoRelay { return named(relay.player.audioTracks, on: relay.player) }
		#endif
		if usesAether { return aether.audioTracks.enumerated().map { i, t in aetherChoice(t, index: i, audio: true) } }
		return usesNative ? selectedNativeTracks(nativeAudio) : named(player.audioTracks, on: player)
	}
	func textTracks() -> [TrackChoice] {
		#if os(iOS)
		if let relay = videoRelay { return named(relay.player.subtitleTracks, on: relay.player) }
		#endif
		if usesAether { return aether.subtitleTracks.enumerated().map { i, t in aetherChoice(t, index: i, audio: false) } }
		return usesNative ? selectedNativeTracks(nativeText) : named(player.subtitleTracks, on: player)
	}

	private func aetherChoice(_ t: TrackInfo, index: Int, audio: Bool) -> TrackChoice {
		var parts = [t.name]
		if let l = t.language, !l.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
		let name = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
		var choice = TrackChoice(name: name.isEmpty ? L("track_n", index + 1) : name)
		choice.aetherID = t.id
		choice.aetherAudio = audio
		choice.selected = audio ? aether.activeAudioTrackIndex == t.id : aether.activeSubtitleTrackIndex == t.id
		return choice
	}

	private func named(_ tracks: [Track], on owner: Player) -> [TrackChoice] {
		tracks.enumerated().map { i, t in
			var parts = [t.name]
			if let l = t.language, !l.isEmpty { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
			if let d = t.trackDescription, !d.isEmpty { parts.append(d) }
			var seen = Set<String>()
			let name = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
			return TrackChoice(name: name.isEmpty ? L("track_n", i + 1) : name, track: t, owner: owner)
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
			if usesAether { aether.clearSubtitle() }
			player.selectedSubtitleTrack = nil
			#if os(iOS)
			videoRelay?.player.selectedSubtitleTrack = nil
			#endif
			subtitle = ""
			say(L("subtitles_set", L("subtitles_off")), 2)
		}
	}

	/// Loads an SRT/VTT (or other) subtitle file. SRT and WebVTT cues are read here (desktop
	/// subtitle_cues), so they are also spoken while an AirPlay conversion plays.
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
		// External subtitle files use the active engine's renderer and spoken-cue path.
		loadedSubtitleFile = copy
		selectedSubtitleName = picked.lastPathComponent
		if usesNative && !isRelayingVideo { fallbackToVLC() }
		if usesAether {
			let track = aether.addExternalSubtitleTrack(ExternalSubtitleTrack(url: copy, name: picked.lastPathComponent, language: nil))
			aether.selectSubtitleTrack(index: track.id)
		} else {
			#if os(iOS)
			let subtitlePlayer = videoRelay?.player ?? player
			#else
			let subtitlePlayer = player
			#endif
			if subtitlePlayer.isPlaying { try? subtitlePlayer.addExternalTrack(from: copy, type: .subtitle, select: true) }
			else { pendingSubtitle = copy }
		}
		say(L("subtitles_set", picked.lastPathComponent), 2)
		cues = []
		cueIndex = nil
		if SubtitleCues.speakableExtensions.contains(copy.pathExtension.lowercased()), let raw = try? Data(contentsOf: copy) {
			cues = SubtitleCues.parse(String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self))
			if !cues.isEmpty && cueTimer == nil {
				cueTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in Task { @MainActor in self?.cueTick() } }
			}
		}
	}

	/// Every other text subtitle libVLC decodes (closed captions, teletext, ASS and the
	/// stream's own tracks) arrives as text: libVLC no longer draws it, the screen shows it.
	private func captionChanged(_ text: String) {
		guard cues.isEmpty, !usesNative, subtitlesAllowed, text != subtitle else { return }
		subtitle = text
		if !text.isEmpty && prefs.speakSubtitles && isPlaying { announce(text) }
	}

	private func cueTick() {
		guard !cues.isEmpty else { return }
		let off = !subtitlesAllowed || !textTracks().contains { $0.isSelected }
		// A positive delay shows cues later. The delay is libVLC's; the engine has none.
		let ms = Int64(sharedPlaybackTime * 1000) - (usesAether ? 0 : player.subtitleDelay.milliseconds)
		let index = off || ms < 0 ? nil : SubtitleCues.active(cues, ms)
		guard index != cueIndex else { return }
		cueIndex = index
		let text = index.map { cues[$0].text } ?? ""
		subtitle = text
		if !text.isEmpty && prefs.speakSubtitles && isPlaying { announce(text) }
	}

	// MARK: cast

	#if os(iOS)
	struct Renderer { let name: String; let item: RendererItem }

	func renderers() -> [Renderer] {
		var seen = Set<String>()
		return found.filter { seen.insert($0.name).inserted }.map { Renderer(name: $0.name, item: $0) }
	}

	/// Moves playback to a Chromecast (libVLC's renderer), or back to this device.
	func cast(to r: Renderer?) {
		guard !closing else { return }
		if let r {
			if usesAether {
				// Conversion reads libVLC's tracks: demote first, then the relay flow opens it.
				usesAether = false
				aetherLoad?.cancel()
				aether.stop()
			}
			prepareVideoRelay(renderer: r); return
		}
		if sharePlayback != nil { SharePlayCenter.shared.leave() }
		let time = sharedPlaybackTime
		castPreparation?.cancel()
		preparingVideo = true
		stopNative()
		PlaybackTeardown.stop(player)
		castTarget = nil
		videoRelay?.stop()
		videoRelay = nil
		casting = nil
		usesNative = PlaybackBackend.preferred(for: request.url) == .native
		usesAether = PlaybackBackend.preferred(for: request.url) == .aether
		if !live && time > 0 { fallbackTime = time }
		preparingVideo = false
		open()
		say(L("cast_stopped"), 2)
	}

	/// The route picker keeps the same AVPlayer while an incompatible source is converted.
	func prepareAirPlay() {
		guard !usesAether else { return }
		guard !usesNative || casting != nil else { return }
		prepareVideoRelay(renderer: nil)
	}

	/// Picking an AirPlay device starts conversion automatically; no Prepare step.
	/// Compatible streams already play natively, and audio-only routes need no video.
	func airPlayDevicePicked() {
		guard !usesNative, !usesAether else { return }
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
				self.castTarget = nil
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
			let subtitles = self.named(self.player.subtitleTracks, on: self.player)
			var subtitle = self.player.selectedSubtitleTrack
			if let name = self.selectedSubtitleName {
				let index = AudioTracks.choose(names: subtitles.map(\.name), describesVideo: subtitles.map { _ in false }, remembered: name, preferAd: false, keywords: [])
				if index >= 0 { subtitle = subtitles[index].track }
			}
			let subtitleID = subtitle?.id
			let tracks = [video.id] + (audio.map { [$0.id] } ?? [])
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
		castTarget = renderer?.item
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
		castTarget = nil
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
		// While PiP runs, the native surface stays attached: detaching the player from
		// its view controller would kill the PiP window.
		nativeVideoAttached = phase != .background || pipActive
		// AetherEngine PiP starts as the app resigns active, the same moment AVKit
		// starts the native player's own PiP.
		if usesAether, phase == .inactive, isPlaying { startPiP() }
		if usesNative || usesAether { return }
		if phase == .background && casting == nil && !videoOff {
			videoOff = true
			player.setVideoEnabled(false)
		} else if phase == .active && videoOff {
			videoOff = false
			player.setVideoEnabled(true)
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
			if usesAether { aether.pause() }
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
		let time = usesNative ? nativePlayer.currentTime().seconds
			: usesAether ? aether.clock.currentTime : vlcSeconds
		return time.isFinite ? max(0, time) + (isRelayingVideo && !live ? relayStartTime : 0) : 0
	}
	var sharedPlaybackRate: Float { isPaused ? 0 : 1 }
	private var vlcSeconds: Double { Double(player.currentTime.milliseconds) / 1000 }
	var sharedPlaybackReady: Bool {
		guard hasPlayed, !buffering, !failed, !closing, retryTask == nil else { return false }
		if usesNative {
			guard nativePlayer.currentItem?.status == .readyToPlay else { return false }
		} else if usesAether {
			guard aether.state == .playing || aether.state == .paused else { return false }
		} else if player.state != .playing && player.state != .paused { return false }
		if let target = sharedSeekTarget {
			guard abs(sharedPlaybackTime - target) < 0.5 else { return false }
			sharedSeekTarget = nil
		}
		return true
	}
	var sharedPlaybackSeekable: Bool { !live && !isRelayingVideo && (usesNative ? nativePlayer.currentItem?.seekableTimeRanges.isEmpty == false : usesAether ? true : player.isSeekable) }
	var sharedPlaybackFailed: Bool { failed || closing }

	func joinSharePlay(_ session: GroupSession<WatchTVActivity>, identifier: String) {
		leaveSharePlay()
		try? player.setPlaybackRate(1.0)
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
				if usesAether { aether.pause() }
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
		try? player.setPlaybackRate(PlaybackRate(rate))
		if usesAether { aether.setRate(rate) }
		if usesNative { nativePlayer.rate = rate }
	}

	func performSharedSeek(seconds: Double) {
		guard sharedPlaybackSeekable, seconds.isFinite else { return }
		let target = min(Double(Int32.max) / 1000, max(0, seconds))
		guard abs(sharedPlaybackTime - target) > 0.2 else { return }
		sharedSeekTarget = target
		if usesNative { nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) }
		else if usesAether { Task { [weak self] in await self?.aether.seek(to: target) } }
		else { try? player.seek(to: .milliseconds(Int64(target * 1000))) }
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

/// AVKit's PiP callbacks for the AetherEngine sample-buffer path: lifecycle goes to the
/// controller (which arms the engine's keepalive), and the PiP window's own transport
/// controls — play/pause and skip — are answered by the engine's PiP source, whose
/// enqueued-frame time axis is the only honest one.
@MainActor
final class PiPBridge: NSObject, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
	weak var owner: PlayerController?

	func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
		owner?.pipStarted()
	}

	func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
		owner?.pipStopped()
	}

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
		owner?.restoreFromPiP()
		completionHandler(true)
	}

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
		owner?.aether.softwarePiPSource?.setPlaying(playing)
	}

	func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
		owner?.aether.softwarePiPSource?.timeRange() ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
	}

	func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
		owner?.aether.softwarePiPSource?.isPaused ?? true
	}

	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
		owner?.aether.softwarePiPSource?.skip(by: skipInterval.seconds)
		completionHandler()
	}

	/// The render size is the engine's business; the window's aspect follows the layer.
	func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

	/// Background audio is a feature of this app, never prohibited for PiP's sake.
	func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
}
