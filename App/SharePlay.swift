import Combine
import GroupActivities
import SwiftUI
import IPTVCore

struct WatchTVActivity: GroupActivity {
	static let activityIdentifier = "dev.serrebi.accessibleiptv.watch"
	let content: ShareContent
	let activationID: UUID
	/// The participant whose one provider connection everyone watches. Nil from v0.2.0, where
	/// each participant opened their own provider.
	let relayHost: UUID?

	init(content: ShareContent, activationID: UUID = UUID(), relayHost: UUID? = nil) {
		self.content = content
		self.activationID = activationID
		self.relayHost = relayHost
	}

	var metadata: GroupActivityMetadata {
		var metadata = GroupActivityMetadata()
		metadata.type = .watchTogether
		metadata.title = content.isValid ? content.name : L("app_name")
		return metadata
	}
}

/// The activity contains public metadata, never a URL. The participant who chose the programme
/// is the relay host: only that device connects to the provider; the others play its relay.
@MainActor
final class SharePlayCenter: ObservableObject {
	static let shared = SharePlayCenter()
	@Published private(set) var isActive = false
	@Published private(set) var status = ""
	@Published private(set) var starting = false
	private var session: GroupSession<WatchTVActivity>?
	private var subscriptions = Set<AnyCancellable>()
	private var listener: Task<Void, Never>?
	private var selection: Task<Void, Never>?
	private var generation = UUID()
	private var currentContent: ShareContent?
	private var activation: Task<Void, Never>?
	private var activationToken = UUID()
	private var activationID: UUID?
	private var activationIssued = false
	private var declinedActivations = Set<UUID>()
	private var channel: RelayChannel?
	private var hosting: (producer: RelayProducer, server: RelayServer, host: RelayHost, player: PlayerController)?
	private var guesting: (guest: RelayGuest, server: RelayServer, content: ShareContent)?

	func listen() {
		guard listener == nil else { return }
		listener = Task { [weak self] in
			for await session in WatchTVActivity.sessions() {
				guard !Task.isCancelled else { return }
				self?.configure(session)
			}
		}
	}

	func content(for player: PlayerController) -> ShareContent? {
		guard !player.localFile, player.casting == nil, let channel = player.channel,
			!player.request.catchup || player.request.archiveStart != nil else { return nil }
		return ShareContent(channel: channel, archiveStart: player.request.archiveStart, archiveStop: player.request.archiveStop)
	}

	func start(_ player: PlayerController) {
		guard !starting, !isActive else { return }
		guard let content = content(for: player) else { report(L("shareplay_unavailable")); return }
		starting = true
		let token = UUID()
		let activity = WatchTVActivity(content: content)
		activationToken = token
		activationID = activity.activationID
		activation = Task {
			defer {
				if activationToken == token {
					activation = nil
					// activate() can return before its session arrives on the separate sequence.
					if !activationIssued { starting = false; activationID = nil }
				}
			}
			let result = await activity.prepareForActivation()
			guard !Task.isCancelled, activationToken == token, AppModel.shared.player === player else { return }
			switch result {
			case .activationPreferred:
				activationIssued = true
				do {
					let activated = try await activity.activate()
					if activationToken == token && !activated { activationIssued = false }
				}
				catch {
					if activationToken == token { activationIssued = false; report(L("shareplay_failed")) }
				}
			case .activationDisabled: report(L("shareplay_call"))
			case .cancelled: break
			@unknown default: report(L("shareplay_failed"))
			}
		}
	}

	func cancelActivation() {
		guard starting || activationID != nil else { return }
		// An already-issued system activation may still deliver a session after cancellation.
		if activationIssued, let activationID { declinedActivations.insert(activationID) }
		activationToken = UUID()
		activation?.cancel()
		activation = nil
		activationID = nil
		activationIssued = false
		starting = false
	}

	/// True when a new local player must wait for the relay instead of opening the provider.
	func hostsNextPlayer(fromSession: Bool) -> Bool { session != nil && !fromSession }

	func playerChanged(_ player: PlayerController, fromSession: Bool) {
		if !fromSession { cancelActivation() }
		guard let session else { return }
		if fromSession && guesting != nil { return }
		guard let content = content(for: player) else {
			leave()
			player.useRelay(nil, request: nil)
			report(L("shareplay_unavailable"))
			return
		}
		selection?.cancel()
		generation = UUID()
		if fromSession {
			// A v0.2.0 participant chose this; its matches can have different provider labels.
			currentContent = session.activity.content
			player.joinSharePlay(session, identifier: session.activity.content.identifier)
			return
		}
		// Chosen here: this device becomes the relay host for everyone.
		currentContent = content
		session.activity = WatchTVActivity(content: content, activationID: session.activity.activationID,
			relayHost: session.localParticipant.id)
		host(content)
	}

	/// The local player stops: its relay stops with it, without reopening the provider.
	func playerClosing(_ player: PlayerController) {
		if hosting?.player === player { stopRelay(reopen: false) }
		if guesting != nil, player.isRelayed { stopRelay(reopen: false) }
	}

	func leave(endForEveryone: Bool = false) {
		cancelActivation()
		guard let session else { return }
		clear()
		if endForEveryone { session.end() } else { session.leave() }
		report(L("shareplay_ended"))
	}

	private func configure(_ session: GroupSession<WatchTVActivity>) {
		if declinedActivations.remove(session.activity.activationID) != nil {
			session.leave()
			return
		}
		let startedHere = activationID != nil && activationID == session.activity.activationID
		if let activationID, activationID != session.activity.activationID { cancelActivation() }
		// Receiving the session completes activation before any remote playback can replace its player.
		starting = false
		activationID = nil
		activationIssued = false
		guard self.session !== session else { return }
		if let old = self.session { clear(); old.leave() }
		self.session = session
		channel = RelayChannel(session)
		isActive = true
		session.$state.receive(on: RunLoop.main).sink { [weak self, weak session] state in
			guard let self, let session, self.session === session else { return }
			if case .invalidated = state { clear(); report(L("shareplay_ended")) }
		}.store(in: &subscriptions)
		session.$activeParticipants.receive(on: RunLoop.main).sink { [weak self, weak session] participants in
			guard let self, let session, self.session === session else { return }
			status = L("shareplay_participants", participants.count)
		}.store(in: &subscriptions)
		session.$activity.receive(on: RunLoop.main).sink { [weak self, weak session] activity in
			guard let self, let session, self.session === session else { return }
			receive(activity)
		}.store(in: &subscriptions)
		session.join()
		if startedHere, let player = AppModel.shared.player, let content = content(for: player) {
			session.activity = WatchTVActivity(content: content, activationID: session.activity.activationID,
				relayHost: session.localParticipant.id)
		}
	}

	private func clear() {
		selection?.cancel()
		selection = nil
		generation = UUID()
		subscriptions.removeAll()
		session = nil
		currentContent = nil
		isActive = false
		status = ""
		AppModel.shared.player?.leaveSharePlay()
		// A guest's picture came from the host and ends with the session. A host keeps watching.
		let wasGuest = guesting != nil
		stopRelay(reopen: true)
		channel = nil
		if wasGuest { AppModel.shared.stopPlayback(leavingSharePlay: false) }
	}

	private func receive(_ activity: WatchTVActivity) {
		guard let session, let relayHost = activity.relayHost, activity.content.isValid else {
			if guesting != nil {
				// A v0.2.0 participant took over: each device opens its own provider again.
				stopRelay(reopen: false)
				AppModel.shared.stopPlayback(leavingSharePlay: false)
			}
			receive(activity.content)
			return
		}
		if relayHost == session.localParticipant.id { host(activity.content) } else { guest(of: relayHost, activity.content) }
	}

	// MARK: relay

	/// This device opens the provider once; its own player and every guest play the relay.
	private func host(_ content: ShareContent) {
		let model = AppModel.shared
		guard let channel, let player = model.player, self.content(for: player) == content else { return }
		if hosting?.player === player { return }
		stopRelay(reopen: false)
		currentContent = content
		let producer = RelayProducer(url: player.request.url, live: player.live)
		let server = RelayServer(buffer: producer.buffer)
		let host = RelayHost(channel: channel, buffer: producer.buffer)
		hosting = (producer, server, host, player)
		Task {
			let url = try? await server.start()
			guard hosting?.host === host else { return }
			guard let url else {
				stopRelay(reopen: true)
				report(L("shareplay_failed"))
				return
			}
			// The direct connection closes before the producer opens: one provider connection at a time.
			player.useRelay(url) { [weak self] pause in self?.setRelayPaused(pause) }
			guard producer.start() else {
				stopRelay(reopen: true)
				report(L("shareplay_failed"))
				return
			}
			host.onRequest = { [weak self] request in self?.setRelayPaused(request.action == .pause) }
			host.start()
			report(L("shareplay_active"))
		}
	}

	private func setRelayPaused(_ paused: Bool) {
		guard let hosting else { return }
		if paused { hosting.producer.pause() } else { hosting.producer.resume() }
		hosting.host.setPaused(paused)
		hosting.player.relayPaused(paused, rejoin: hosting.producer.live)
	}

	/// This device plays the host's relay and never contacts the provider.
	private func guest(of host: UUID, _ content: ShareContent) {
		let model = AppModel.shared
		guard let channel else { return }
		if let guesting, guesting.guest.host == host, guesting.content == content { return }
		stopRelay(reopen: false)
		selection?.cancel()
		generation = UUID()
		currentContent = content
		model.stopPlayback(leavingSharePlay: false)
		let guest = RelayGuest(channel: channel, host: host)
		let server = RelayServer(buffer: guest.buffer)
		guesting = (guest, server, content)
		report(L("shareplay_loading"))
		let live = content.kind == Channel.kindLive && content.archiveStart == nil
		let request: (Bool) -> Void = { [weak guest] pause in guest?.request(pause ? .pause : .play) }
		Task {
			let url = try? await server.start()
			guard guesting?.guest === guest else { return }
			guard let url else {
				stopRelay(reopen: false)
				report(L("shareplay_failed"))
				return
			}
			model.play(url, title: content.name, key: "", catchup: !live, fromSharePlay: true)
			model.player?.useRelay(url, request: request)
			guest.onReset = { model.player?.useRelay(url, request: request) }
			guest.onPaused = { paused in model.player?.relayPaused(paused, rejoin: live) }
			guest.start()
			report(L("shareplay_active"))
		}
	}

	/// `reopen`: a host still watching goes back to its own provider connection.
	private func stopRelay(reopen: Bool) {
		if let hosting {
			self.hosting = nil
			hosting.host.stop()
			hosting.producer.stop()
			hosting.server.stop()
			if reopen && AppModel.shared.player === hosting.player { hosting.player.useRelay(nil, request: nil) }
		}
		if let guesting {
			self.guesting = nil
			guesting.guest.stop()
			guesting.server.stop()
		}
	}

	private func receive(_ content: ShareContent) {
		let model = AppModel.shared
		guard content.isValid else {
			selection?.cancel()
			generation = UUID()
			currentContent = nil
			model.stopPlayback(leavingSharePlay: false)
			report(L("shareplay_unavailable"))
			return
		}
		if currentContent == content, model.player?.isSharingPlayback == true { return }
		selection?.cancel()
		let token = UUID()
		generation = token
		currentContent = content
		if let player = model.player, self.content(for: player) == content {
			if let session { player.joinSharePlay(session, identifier: content.identifier) }
			return
		}
		model.stopPlayback(leavingSharePlay: false)
		report(L("shareplay_loading"))
		selection = Task {
			let library = model.library
			let section = content.kind == Channel.kindLive ? Library.live : content.kind == Channel.kindMovie ? Library.movies : Library.series
			if !library.isLoaded(section) { _ = await library.load(section, force: false) }
			var candidates = library.list(section)
			if content.kind == Channel.kindEpisode {
				let shows = candidates.filter { Lists.lowerName($0.name) == Lists.lowerName(content.group) }
				var episodes: [Channel] = []
				for show in shows {
					guard !Task.isCancelled, generation == token else { return }
					episodes += (try? await library.episodes(show)) ?? []
				}
				candidates = episodes
			}
			let loadedCandidates = candidates
			let matches = await Task.detached { content.matches(in: loadedCandidates) }.value
			guard !Task.isCancelled, generation == token, session != nil else { return }
			guard matches.count == 1, let channel = matches.first else { report(L("shareplay_missing")); return }
			let url: String?
			if let start = content.archiveStart, let stop = content.archiveStop {
				url = await library.catchupUrl(channel, start: start, stop: stop)
			} else {
				url = try? await library.resolveUrl(channel)
			}
			guard !Task.isCancelled, generation == token, session != nil else { return }
			guard let url else { report(L("shareplay_missing")); return }
			model.play(url, title: channel.name, key: channel.key, catchup: content.archiveStart != nil,
				channel: channel, archiveStart: content.archiveStart, archiveStop: content.archiveStop, fromSharePlay: true)
			status = L("shareplay_active")
		}
	}

	private func report(_ text: String) {
		status = text
		AppModel.shared.setStatus(text)
	}
}

struct SharePlayControls: View {
	@ObservedObject var center = SharePlayCenter.shared
	@ObservedObject var player: PlayerController
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if center.isActive {
				SharePlaySessionControls()
			} else {
				if !center.status.isEmpty { Text(center.status) }
				Button { center.start(player) } label: { Label(L("shareplay_start"), systemImage: "shareplay") }
					.disabled(center.starting || center.content(for: player) == nil)
				if center.content(for: player) == nil { Text(L("shareplay_unavailable")).font(.caption) }
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.buttonStyle(.bordered).padding(.horizontal)
	}
}

struct SharePlaySessionControls: View {
	@ObservedObject private var center = SharePlayCenter.shared
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(center.status)
			Button(L("shareplay_leave")) { center.leave() }
			Button(L("shareplay_end"), role: .destructive) { center.leave(endForEveryone: true) }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.buttonStyle(.bordered)
	}
}
