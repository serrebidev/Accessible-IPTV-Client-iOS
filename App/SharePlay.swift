import Combine
import GroupActivities
import SwiftUI
import IPTVCore

struct WatchTVActivity: GroupActivity {
	static let activityIdentifier = "dev.serrebi.accessibleiptv.watch"
	let content: ShareContent

	var metadata: GroupActivityMetadata {
		var metadata = GroupActivityMetadata()
		metadata.type = .watchTogether
		metadata.title = content.isValid ? content.name : L("app_name")
		return metadata
	}
}

/// The activity contains public metadata. Every device resolves its own authenticated URL.
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
	private var activationContent: ShareContent?
	private var activationIssued = false
	private var declinedActivation: ShareContent?

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
		activationToken = token
		activationContent = content
		declinedActivation = nil
		activation = Task {
			defer {
				if activationToken == token { starting = false; activation = nil; activationContent = nil; activationIssued = false }
			}
			let activity = WatchTVActivity(content: content)
			let result = await activity.prepareForActivation()
			guard !Task.isCancelled, activationToken == token, AppModel.shared.player === player else { return }
			switch result {
			case .activationPreferred:
				activationIssued = true
				do { try await activity.activate() }
				catch { if activationToken == token { report(L("shareplay_failed")) } }
			case .activationDisabled: report(L("shareplay_call"))
			case .cancelled: break
			@unknown default: report(L("shareplay_failed"))
			}
		}
	}

	func cancelActivation() {
		guard starting else { return }
		// An already-issued system activation may still deliver a session after cancellation.
		if activationIssued { declinedActivation = activationContent }
		activationToken = UUID()
		activation?.cancel()
		activation = nil
		activationContent = nil
		activationIssued = false
		starting = false
	}

	func playerChanged(_ player: PlayerController, fromSession: Bool) {
		if !fromSession { cancelActivation() }
		guard let session else { return }
		guard let content = content(for: player) else {
			leave()
			report(L("shareplay_unavailable"))
			return
		}
		selection?.cancel()
		generation = UUID()
		// Remote matches can have different provider labels; retain the session's common identifier.
		let shared = fromSession ? session.activity.content : content
		currentContent = shared
		player.joinSharePlay(session, identifier: shared.identifier)
		if !fromSession && session.activity.content != content { session.activity = WatchTVActivity(content: content) }
	}

	func leave(endForEveryone: Bool = false) {
		cancelActivation()
		guard let session else { return }
		clear()
		if endForEveryone { session.end() } else { session.leave() }
		report(L("shareplay_ended"))
	}

	private func configure(_ session: GroupSession<WatchTVActivity>) {
		if declinedActivation == session.activity.content {
			declinedActivation = nil
			session.leave()
			return
		}
		// Receiving the session completes activation before any remote playback can replace its player.
		starting = false
		activationContent = nil
		activationIssued = false
		guard self.session !== session else { return }
		if let old = self.session { clear(); old.leave() }
		self.session = session
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
			receive(activity.content)
		}.store(in: &subscriptions)
		session.join()
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
