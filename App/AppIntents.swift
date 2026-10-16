import SwiftUI
import IPTVCore

#if os(iOS)
import AppIntents
import CryptoKit
import CoreSpotlight
import CoreTransferable

struct TVChannelEntity: AppEntity, Transferable {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "channel"
	static var defaultQuery = TVChannelQuery()
	let id: String
	@Property(title: "channel") var name: String
	@Property(title: "groups") var category: String
	@Property(title: "channel_number") var number: String
	let spokenName: String

	init(_ channel: Channel) {
		id = Self.identifier(channel)
		spokenName = ChannelDiscovery.spokenName(channel.name)
		let publicName = ChannelDiscovery.publicText(channel.name)
		name = publicName.isEmpty ? L("channel") : publicName
		category = ChannelDiscovery.publicText(channel.group)
		number = ChannelDiscovery.publicText(channel.number)
	}

	static func identifier(_ channel: Channel) -> String {
		SHA256.hash(data: Data(channel.key.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(Format.sentences([category, number]))",
			synonyms: [spokenName, number].filter { !$0.isEmpty && $0 != name }.map { LocalizedStringResource(stringLiteral: $0) })
	}

	static var transferRepresentation: some TransferRepresentation { ProxyRepresentation(exporting: \.name) }
}

@available(iOS 18, *)
extension TVChannelEntity: IndexedEntity {
	var attributeSet: CSSearchableItemAttributeSet { ChannelSpotlight.attributes(self) }
}

struct TVChannelQuery: EntityStringQuery, EntityPropertyQuery {
	static var properties = QueryProperties {
		Property(\TVChannelEntity.$name) {
			EqualToComparator { value in { (ch: Channel) in ChannelDiscovery.nameMatches(ch.name, value, exact: true) } }
			ContainsComparator { value in { (ch: Channel) in ChannelDiscovery.nameMatches(ch.name, value, exact: false) } }
		}
		Property(\TVChannelEntity.$category) {
			EqualToComparator { value in { (ch: Channel) in ChannelDiscovery.publicText(ch.group).compare(value, options: .caseInsensitive) == .orderedSame } }
			ContainsComparator { value in { (ch: Channel) in ChannelDiscovery.publicText(ch.group).localizedCaseInsensitiveContains(value) } }
		}
		Property(\TVChannelEntity.$number) {
			EqualToComparator { value in { (ch: Channel) in ChannelDiscovery.publicText(ch.number) == value } }
		}
	}
	static var sortingOptions = SortingOptions {
		SortableBy(\TVChannelEntity.$name)
		SortableBy(\TVChannelEntity.$category)
		SortableBy(\TVChannelEntity.$number)
	}

	static func resolve(_ identifiers: [String], in channels: [Channel]) -> [TVChannelEntity] {
		let byID = Dictionary(channels.map { (TVChannelEntity.identifier($0), $0) }, uniquingKeysWith: { first, _ in first })
		return identifiers.compactMap { byID[$0].map(TVChannelEntity.init) }
	}

	static func find(_ channels: [Channel], matching comparators: [(Channel) -> Bool], mode: ComparatorMode,
		sortedBy: [Sort<TVChannelEntity>], limit: Int?) -> [TVChannelEntity] {
		var matches = channels.filter { ch in
			comparators.isEmpty || (mode == .and ? comparators.allSatisfy { $0(ch) } : comparators.contains { $0(ch) })
		}
		for sort in sortedBy.reversed() {
			let field: (Channel) -> String
			switch sort.by {
			case \TVChannelEntity.$name: field = { ChannelDiscovery.publicText($0.name) }
			case \TVChannelEntity.$category: field = { ChannelDiscovery.publicText($0.group) }
			case \TVChannelEntity.$number: field = { ChannelDiscovery.publicText($0.number) }
			default: continue
			}
			matches.sort { a, b in
				let order = field(a).localizedStandardCompare(field(b))
				return sort.order == .ascending ? order == .orderedAscending : order == .orderedDescending
			}
		}
		return matches.prefix(max(0, limit ?? matches.count)).map(TVChannelEntity.init)
	}

	@MainActor func entities(for identifiers: [String]) async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		return await Task.detached { Self.resolve(identifiers, in: channels) }.value
	}

	@MainActor func entities(matching comparators: [(Channel) -> Bool], mode: ComparatorMode,
		sortedBy: [Sort<TVChannelEntity>], limit: Int?) async throws -> [TVChannelEntity] {
		let channels = try await SiriLibrary.live()
		return await Task.detached { Self.find(channels, matching: comparators, mode: mode, sortedBy: sortedBy, limit: limit) }.value
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
enum SiriLibrary {
	private static var loading: Task<[Channel], Error>?

	static func live() async throws -> [Channel] {
		let model = AppModel.shared
		guard !model.prefs.sources.isEmpty else { throw ActionError.message(L("no_sources")) }
		if let loading { return try await loading.value }
		if !model.library.isLoaded(Library.live) || !Source.samePlaylists(model.library.liveSnapshot.sources, model.prefs.sources) {
			let task = Task {
				let errors = await model.library.load(Library.live, force: false)
				if model.library.channels.isEmpty, !errors.isEmpty { throw ActionError.message(L("siri_failed")) }
				return current()
			}
			loading = task
			defer { loading = nil }
			return try await task.value
		}
		return current()
	}

	private static func current() -> [Channel] {
		let model = AppModel.shared, snapshot = model.library.liveSnapshot
		let active = Set(snapshot.sources.filter { loaded in model.prefs.sources.contains { $0.refersToSamePlaylist(as: loaded) } }.map(\.id))
		return snapshot.channels.filter { active.contains($0.sourceId) }
	}

	static func channel(_ entity: TVChannelEntity) async throws -> Channel {
		let channels = try await live()
		guard let channel = await Task.detached(operation: { channels.first { TVChannelEntity.identifier($0) == entity.id } }).value else {
			throw ActionError.message(L("channel_unavailable"))
		}
		return channel
	}

	static func tune(_ entity: TVChannelEntity) async throws -> TVChannelEntity {
		let ch = try await channel(entity)
		let model = AppModel.shared
		guard let url = try? await model.library.resolveUrl(ch) else { throw ActionError.message(L("siri_failed")) }
		let current = TVChannelEntity(ch)
		model.rememberChannel(ch)
		model.play(url, title: current.name, key: ch.key, channel: ch)
		return current
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
	static var parameterSummary: some ParameterSummary { Summary("\(\.$channel)") }

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<TVChannelEntity> {
		return .result(value: try await SiriLibrary.tune(channel))
	}
}

struct OpenTVChannelIntent: OpenIntent {
	static var title: LocalizedStringResource = "open_channel"
	static var openAppWhenRun = true
	@Parameter(title: "channel") var target: TVChannelEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$target)") }

	@MainActor func perform() async throws -> some IntentResult {
		_ = try await SiriLibrary.tune(target)
		return .result()
	}
}

struct WhatsOnChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "whats_on_channel"
	@Parameter(title: "channel") var channel: TVChannelEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$channel)") }

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
	static var parameterSummary: some ParameterSummary { Summary("\(\.$query)") }

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
	static var parameterSummary: some ParameterSummary { Summary("\(\.$channel)") }

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
		AppShortcut(intent: TuneChannelIntent(), phrases: [
			"Play \(\.$channel) in \(.applicationName)",
			"Tune to \(\.$channel) in \(.applicationName)",
			"Watch \(\.$channel) in \(.applicationName)",
			"Play TV in \(.applicationName)",
			"Tune to a channel in \(.applicationName)",
			"Watch TV in \(.applicationName)"
		], shortTitle: "tune_channel", systemImageName: "tv")
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
