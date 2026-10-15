import SwiftUI
import IPTVCore

#if os(iOS)
import AppIntents

struct TVChannelEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "channel"
	static var defaultQuery = TVChannelQuery()
	let id: String
	@Property(title: "channel") var name: String
	@Property(title: "groups") var category: String
	@Property(title: "channel_number") var number: String

	init(_ channel: Channel) {
		id = channel.key
		name = channel.name
		category = channel.group
		number = channel.number
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(Format.sentences([category, number]))")
	}
}

struct TVChannelQuery: EntityStringQuery {
	@MainActor func entities(for identifiers: [String]) async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		let ids = Set(identifiers)
		return channels.filter { ids.contains($0.key) }.map(TVChannelEntity.init)
	}

	@MainActor func entities(matching string: String) async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		let matches = await Task.detached { Array(ChannelDiscovery.matching(channels, string).prefix(20)) }.value
		return matches.map(TVChannelEntity.init)
	}

	@MainActor func suggestedEntities() async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		let prefs = AppModel.shared.prefs
		let favorites = prefs.favorites, recent = prefs.recent
		let matches = await Task.detached { ChannelDiscovery.suggestions(channels, favorites: favorites, recent: recent) }.value
		return matches.map(TVChannelEntity.init)
	}
}

@MainActor
private enum SiriLibrary {
	static func live() async throws -> [Channel] {
		let model = AppModel.shared
		guard !model.prefs.sources.isEmpty else { throw ActionError.message(L("no_sources")) }
		if !model.library.isLoaded(Library.live) || model.sourcesChanged {
			let errors = await model.library.load(Library.live, force: false)
			if model.library.channels.isEmpty, !errors.isEmpty { throw ActionError.message(L("load_errors", errors.joined(separator: "; "))) }
		}
		return model.library.channels
	}

	static func channel(_ entity: TVChannelEntity) async throws -> Channel {
		guard let channel = try await live().first(where: { $0.key == entity.id }) else {
			throw ActionError.message(L("channel_unavailable"))
		}
		return channel
	}

	enum ActionError: LocalizedError {
		case message(String)
		var errorDescription: String? { switch self { case .message(let text): return text } }
	}
}

struct TuneChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "tune_channel"
	static var openAppWhenRun = true
	@Parameter(title: "channel") var channel: TVChannelEntity

	@MainActor func perform() async throws -> some IntentResult {
		let ch = try await SiriLibrary.channel(channel)
		let model = AppModel.shared
		let url = try await model.library.resolveUrl(ch)
		model.prefs.addRecent(ch.key)
		model.play(url, title: ch.name, key: ch.key)
		return .result()
	}
}

struct WhatsOnChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "whats_on_channel"
	@Parameter(title: "channel") var channel: TVChannelEntity

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
		let ch = try await SiriLibrary.channel(channel)
		let guide = AppModel.shared.library.epg.nowNext(ch)
		var parts = [ch.name]
		if let now = guide.now { parts.append(L("now_programme", Format.programme(now))) }
		if let next = guide.next { parts.append(L("next_programme", Format.programme(next))) }
		if guide.isEmpty { parts.append(L("no_guide_for", ch.name)) }
		let text = Format.sentences(parts)
		return .result(value: text, dialog: "\(text)")
	}
}

struct SearchGuideIntent: AppIntent {
	static var title: LocalizedStringResource = "search_guide"
	@Parameter(title: "search") var query: String

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
		let channels = try await SiriLibrary.live()
		let epg = AppModel.shared.library.epg
		let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !term.isEmpty else { throw SiriLibrary.ActionError.message(L("no_matches")) }
		let results = await Task.detached { epg.search(term, channels) }.value
		// shortcut: read five matches aloud; the full guide search remains available in the app.
		let lines = results.prefix(5).map { p, ch in "\(ch.name). \(p.title). \(Format.dateTime(p.start)). \(Format.time(p.stop))" }
		let text = lines.isEmpty ? L(epg.hasGuide ? "no_matches" : "no_guide") : lines.joined(separator: "\n")
		return .result(value: text, dialog: "\(text)")
	}
}

struct OpenChannelGuideIntent: AppIntent {
	static var title: LocalizedStringResource = "channel_guide"
	static var openAppWhenRun = true
	@Parameter(title: "channel") var channel: TVChannelEntity

	@MainActor func perform() async throws -> some IntentResult {
		let ch = try await SiriLibrary.channel(channel)
		let model = AppModel.shared
		model.minimizePlayer()
		model.selectedTab = 1
		model.guidePath = [.channelGuide(ch.key)]
		return .result()
	}
}

struct PauseTVIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "pause"
	@MainActor func perform() async throws -> some IntentResult {
		guard let player = AppModel.shared.player else { throw SiriLibrary.ActionError.message(L("playback_unavailable")) }
		player.pause()
		return .result()
	}
}

struct ResumeTVIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "play"
	@MainActor func perform() async throws -> some IntentResult {
		guard let player = AppModel.shared.player else { throw SiriLibrary.ActionError.message(L("playback_unavailable")) }
		player.resume()
		return .result()
	}
}

struct StopTVIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "stop_playback"
	@MainActor func perform() async throws -> some IntentResult {
		AppModel.shared.stopPlayback()
		return .result()
	}
}

struct IPTVShortcuts: AppShortcutsProvider {
	static var appShortcuts: [AppShortcut] {
		AppShortcut(intent: TuneChannelIntent(), phrases: ["Play \(\.$channel) in \(.applicationName)"], shortTitle: "tune_channel", systemImageName: "tv")
		AppShortcut(intent: WhatsOnChannelIntent(), phrases: ["What is on \(\.$channel) in \(.applicationName)"], shortTitle: "whats_on_channel", systemImageName: "list.bullet.rectangle")
		AppShortcut(intent: SearchGuideIntent(), phrases: ["Search the guide in \(.applicationName)"], shortTitle: "search_guide", systemImageName: "magnifyingglass")
		AppShortcut(intent: OpenChannelGuideIntent(), phrases: ["Show the guide for \(\.$channel) in \(.applicationName)"], shortTitle: "channel_guide", systemImageName: "calendar")
		AppShortcut(intent: PauseTVIntent(), phrases: ["Pause playback in \(.applicationName)"], shortTitle: "pause", systemImageName: "pause")
		AppShortcut(intent: ResumeTVIntent(), phrases: ["Resume playback in \(.applicationName)"], shortTitle: "play", systemImageName: "play")
		AppShortcut(intent: StopTVIntent(), phrases: ["Stop playback in \(.applicationName)"], shortTitle: "stop_playback", systemImageName: "stop")
	}
}
#endif

extension View {
	@ViewBuilder func siriChannel(_ channel: Channel?) -> some View {
		#if os(iOS)
		if #available(iOS 18.4, *), let channel {
			appEntityIdentifier(EntityIdentifier(for: TVChannelEntity(channel)))
		} else { self }
		#else
		self
		#endif
	}
}
