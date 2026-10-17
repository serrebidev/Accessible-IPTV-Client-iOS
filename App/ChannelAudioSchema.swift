#if os(iOS) && canImport(MediaIntents)
import AppIntents
import IPTVCore

// The audio-domain schemas are Apple's contract for "play this content" through Siri AI: without
// a schema the system answers that the app does not support playing content. They are iOS 27 APIs,
// and applying the macro to an existing type makes that type iOS 27-only, so TVChannelEntity and
// the intents around it cannot carry them. These types mirror that entity for the system instead.
// `canImport(MediaIntents)` stands in for "this SDK has the iOS 27 schemas", so an older Xcode
// still builds everything here as nothing.

@available(iOS 27.0, *)
@AppEntity(schema: .audio.liveRadioStation)
struct LiveChannelSchemaEntity {
	static let defaultQuery = LiveChannelSchemaQuery()

	/// The same stable hash TVChannelEntity and the Spotlight index use.
	let id: String
	/// What Siri says and matches on: the spoken name, without provider decoration.
	var title: String
	var providerName: String?
	var group: String?
	var number: String?
	/// The provider's own label, kept as an alternate name so it matches when it is read out.
	var providerLabel: String?

	var displayRepresentation: DisplayRepresentation {
		let alternate = [providerLabel, number].compactMap { $0 }.filter { !$0.isEmpty && $0 != title }
		return DisplayRepresentation(title: "\(title)", subtitle: "\(Format.sentences([group ?? "", number ?? ""]))",
			synonyms: alternate.map { LocalizedStringResource(stringLiteral: $0) })
	}

	init(_ channel: Channel) {
		id = TVChannelEntity.identifier(channel)
		let spoken = ChannelDiscovery.spokenName(channel.name)
		let label = ChannelDiscovery.publicText(channel.name)
		let groupText = ChannelDiscovery.publicText(channel.group)
		let numberText = ChannelDiscovery.publicText(channel.number)
		group = groupText.isEmpty ? nil : groupText
		number = numberText.isEmpty ? nil : numberText
		providerLabel = label.isEmpty || label == spoken ? nil : label
		// An unnamed entry's label is its credential-bearing URL and is useless as a title, so
		// fall back to what someone can actually say: the number, then the group.
		title = !spoken.isEmpty ? spoken : (!numberText.isEmpty ? numberText : (!groupText.isEmpty ? groupText : L("channel")))
	}
}

@available(iOS 27.0, *)
struct LiveChannelSchemaQuery: EntityStringQuery {
	@MainActor func entities(for identifiers: [String]) async throws -> [LiveChannelSchemaEntity] {
		let channels = try await SiriLibrary.live()
		let wanted = Set(identifiers)
		return await Task.detached {
			channels.filter { wanted.contains(TVChannelEntity.identifier($0)) }.map(LiveChannelSchemaEntity.init)
		}.value
	}

	@MainActor func entities(matching string: String) async throws -> [LiveChannelSchemaEntity] {
		let channels = try await SiriLibrary.live()
		return await Task.detached {
			ChannelDiscovery.resolve(channels, string).map(LiveChannelSchemaEntity.init)
		}.value
	}

	@MainActor func suggestedEntities() async throws -> [LiveChannelSchemaEntity] {
		let channels = try await SiriLibrary.live()
		let prefs = AppModel.shared.prefs
		let favorites = prefs.favorites, recent = prefs.recent
		return await Task.detached {
			ChannelDiscovery.suggestions(channels, favorites: favorites, recent: recent).map(LiveChannelSchemaEntity.init)
		}.value
	}
}

@available(iOS 27.0, *)
@UnionValue
enum ChannelAudioItem {
	case liveRadioStation(LiveChannelSchemaEntity)
}

@available(iOS 27.0, *)
extension ChannelAudioItem {
	var channelIdentifier: String {
		switch self {
		case .liveRadioStation(let station): return station.id
		}
	}
}

/// A live channel is playing or not: there is nothing to shuffle or repeat. The schema requires
/// the parameter, so the intent accepts it and ignores it.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum ChannelPlaybackAttributes: String {
	case shuffle
	case `repeat`

	static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
		.shuffle: "shuffle",
		.repeat: "repeat"
	]
}

/// One live stream at a time, so a queue position is accepted and ignored like the attributes above.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum ChannelQueueInsertionLocation: String {
	case next
	case tail

	static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
		.next: "play_next",
		.tail: "play_last"
	]
}

/// The schema asks the playback intent to hand back what a warm-up loaded. This app never
/// pre-loads a second channel, so the result only carries the channel it was given.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct ChannelWarmupResult {
	static let defaultQuery = ChannelWarmupResultQuery()

	let id: String

	var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "channel") }
}

@available(iOS 27.0, *)
struct ChannelWarmupResultQuery: EntityStringQuery {
	func entities(for identifiers: [String]) async throws -> [ChannelWarmupResult] {
		identifiers.map { ChannelWarmupResult(id: $0) }
	}

	func entities(matching string: String) async throws -> [ChannelWarmupResult] { [] }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayChannelAudioIntent: AudioPlaybackIntent {
	static var openAppWhenRun = true

	var audioEntity: ChannelAudioItem
	var playbackAttributes: Set<ChannelPlaybackAttributes>
	var warmupAudioQueueResult: ChannelWarmupResult?
	var queueLocation: ChannelQueueInsertionLocation?

	@MainActor func perform() async throws -> some IntentResult {
		let identifier = audioEntity.channelIdentifier
		let channels = try await SiriLibrary.live()
		guard let entity = await Task.detached(operation: { TVChannelQuery.resolve([identifier], in: channels).first }).value else {
			throw SiriLibrary.ActionError.message(L("channel_unavailable"))
		}
		_ = try await SiriLibrary.tune(entity)
		return .result()
	}
}
#endif
