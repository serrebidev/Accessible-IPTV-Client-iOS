import SwiftUI
import IPTVCore

#if os(iOS)
import AppIntents
import CoreSpotlight
import CryptoKit

struct TVChannelEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "channel"
	static var defaultQuery = TVChannelQuery()
	let id: String
	@Property(title: "channel") var name: String
	@Property(title: "groups") var category: String
	@Property(title: "channel_number") var number: String

	init(_ channel: Channel) {
		id = Self.identifier(channel)
		let publicName = ChannelDiscovery.publicText(channel.name)
		name = publicName.isEmpty ? L("channel") : publicName
		category = ChannelDiscovery.publicText(channel.group)
		number = ChannelDiscovery.publicText(channel.number)
	}

	static func identifier(_ channel: Channel) -> String {
		SHA256.hash(data: Data(channel.key.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(Format.sentences([category, number]))")
	}
}

struct TVChannelQuery: EntityStringQuery {
	@MainActor func entities(for identifiers: [String]) async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		let ids = Set(identifiers)
		return await Task.detached { channels.filter { ids.contains(TVChannelEntity.identifier($0)) }.map(TVChannelEntity.init) }.value
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
		// Siri matches spoken channel names in phrases only against these: more than the 20 shown in pickers.
		let matches = await Task.detached { ChannelDiscovery.suggestions(channels, favorites: favorites, recent: recent, limit: 100) }.value
		return matches.map(TVChannelEntity.init)
	}
}

/// Spotlight's semantic index lets Siri and Apple Intelligence find channels by name.
@available(iOS 18.0, *)
extension TVChannelEntity: IndexedEntity {}

@MainActor
enum SiriIndex {
	/// Reindexes favourites, recent channels and the rest of the playlist's order, bounded.
	static func update() {
		guard #available(iOS 18.0, *) else { return }
		let model = AppModel.shared
		let channels = model.library.channels, favorites = model.prefs.favorites, recent = model.prefs.recent
		Task.detached {
			let entities = ChannelDiscovery.suggestions(channels, favorites: favorites, recent: recent, limit: 1000).map(TVChannelEntity.init)
			let index = CSSearchableIndex.default()
			try? await index.deleteAppEntities(ofType: TVChannelEntity.self)
			try? await index.indexAppEntities(entities)
		}
	}

	/// A channel tuned in the app: Siri learns it for suggestions.
	static func tuned(_ channel: Channel) {
		guard channel.isLive else { return }
		_ = IntentDonationManager.shared.donate(intent: TuneChannelIntent(channel: TVChannelEntity(channel)))
	}
}

@MainActor
private enum SiriLibrary {
	static func live() async throws -> [Channel] {
		let model = AppModel.shared
		guard !model.prefs.sources.isEmpty else { throw ActionError.message(L("no_sources")) }
		if !model.library.isLoaded(Library.live) || model.sourcesChanged {
			let errors = await model.library.load(Library.live, force: false)
			if model.library.channels.isEmpty, !errors.isEmpty { throw ActionError.message(L("siri_failed")) }
		}
		return model.library.channels
	}

	static func tune(_ entity: TVChannelEntity) async throws {
		let ch = try await channel(entity)
		let model = AppModel.shared
		guard let url = try? await model.library.resolveUrl(ch) else { throw ActionError.message(L("siri_failed")) }
		model.prefs.addRecent(ch.key)
		model.play(url, title: entity.name, key: ch.key)
	}

	static func channel(_ entity: TVChannelEntity) async throws -> Channel {
		let channels = try await live()
		guard let channel = await Task.detached(operation: { channels.first { TVChannelEntity.identifier($0) == entity.id } }).value else {
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

	init() {}
	init(channel: TVChannelEntity) { self.channel = channel }

	@MainActor func perform() async throws -> some IntentResult {
		try await SiriLibrary.tune(channel)
		return .result()
	}
}

/// What Spotlight and Siri run when a channel result is opened. Hidden from the Shortcuts list,
/// where Tune channel does the same.
struct OpenChannelIntent: OpenIntent {
	static var title: LocalizedStringResource = "tune_channel"
	static var isDiscoverable = false
	@Parameter(title: "channel") var target: TVChannelEntity

	@MainActor func perform() async throws -> some IntentResult {
		try await SiriLibrary.tune(target)
		return .result()
	}
}

struct WhatsOnChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "whats_on_channel"
	@Parameter(title: "channel") var channel: TVChannelEntity

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
		let ch = try await SiriLibrary.channel(channel)
		let guide = AppModel.shared.library.epg.nowNext(ch)
		var parts = [channel.name]
		if let now = guide.now { parts.append(L("now_programme", Format.programme(now))) }
		if let next = guide.next { parts.append(L("next_programme", Format.programme(next))) }
		if guide.isEmpty { parts.append(L("no_guide_for", channel.name)) }
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
		let lines = results.prefix(5).map { p, ch in "\(TVChannelEntity(ch).name). \(p.title). \(Format.dateTime(p.start)). \(Format.time(p.stop))" }
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
		AppShortcut(intent: TuneChannelIntent(), phrases: ["Play \(\.$channel) in \(.applicationName)", "Watch \(\.$channel) in \(.applicationName)"], shortTitle: "tune_channel", systemImageName: "tv")
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
	@ViewBuilder func siriChannel(_ channel: Channel?, active: Bool = true) -> some View {
		#if os(iOS)
		if #available(iOS 18.2, *), let channel {
			userActivity("dev.serrebi.accessibleiptv.channel", isActive: active) { activity in
				let entity = TVChannelEntity(channel)
				activity.title = entity.name
				activity.appEntityIdentifier = EntityIdentifier(for: entity)
				activity.isEligibleForHandoff = false
			}
		} else { self }
		#else
		self
		#endif
	}
}
