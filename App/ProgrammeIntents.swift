#if os(iOS)
import AppIntents
import CoreSpotlight
import CryptoKit
import CoreTransferable
import UserNotifications
import IPTVCore

/// One guide entry as an entity Siri, Spotlight and Shortcuts can pass around.
/// The identifier is the channel key plus the start time in milliseconds: a
/// guide slot is unique per channel, and keeping both in the id makes the
/// entity resolvable without scanning the whole guide again.
struct ProgrammeEntity: AppEntity, Transferable {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "programme"
	static var defaultQuery = ProgrammeQuery()
	let id: String
	@Property(title: "programme") var title: String
	@Property(title: "channel") var channelName: String
	@Property(title: "groups") var category: String
	@Property(title: "programme_details") var details: String
	@Property(title: "programme_start") var start: Date
	@Property(title: "programme_end") var stop: Date
	let channelKey: String
	let startMs: Int64
	let stopMs: Int64

	init(_ programme: Programme, _ channel: Channel) {
		// Plain stored properties first: assigning a @Property counts as a
		// use of self until every plain property is initialized.
		id = Self.identifier(programme)
		channelKey = programme.channelKey
		startMs = programme.start
		stopMs = programme.stop
		let publicTitle = ChannelDiscovery.publicText(programme.title)
		title = publicTitle.isEmpty ? L("programme") : publicTitle
		let publicChannel = ChannelDiscovery.publicText(channel.name)
		channelName = publicChannel.isEmpty ? ChannelDiscovery.publicText(programme.channelName) : publicChannel
		category = ChannelDiscovery.publicText(channel.group)
		details = ChannelDiscovery.publicText(programme.description)
		start = Date(timeIntervalSince1970: Double(programme.start) / 1000)
		stop = Date(timeIntervalSince1970: Double(programme.stop) / 1000)
	}

	static func identifier(_ programme: Programme) -> String {
		"\(programme.channelKey)|\(programme.start)"
	}

	/// The channel key and start time an identifier was built from.
	static func parse(_ identifier: String) -> (channelKey: String, startMs: Int64)? {
		guard let cut = identifier.lastIndex(of: "|"), let start = Int64(identifier[identifier.index(after: cut)...]) else { return nil }
		return (String(identifier[..<cut]), start)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(title)", subtitle: "\(Format.sentences([channelName, Format.dateTime(startMs)]))")
	}

	static var transferRepresentation: some TransferRepresentation { ProxyRepresentation(exporting: \.title) }
}

@available(iOS 18, *)
extension ProgrammeEntity: IndexedEntity {
	var attributeSet: CSSearchableItemAttributeSet { ProgrammeSpotlight.attributes(self) }
}

struct ProgrammeQuery: EntityStringQuery {
	/// Pure resolution shared by the query and the tests: an identifier names
	/// one channel and start time, and the programme is whatever the guide
	/// holds in that slot.
	static func resolve(_ identifiers: [String], in pairs: [(Programme, Channel)]) -> [ProgrammeEntity] {
		let bySlot = Dictionary(pairs.map { ("\(($0.0.channelKey))|\($0.0.start)", $0) }, uniquingKeysWith: { first, _ in first })
		return identifiers.compactMap { bySlot[$0].map { ProgrammeEntity($0.0, $0.1) } }
	}

	static func entities(from pairs: [(Programme, Channel)], limit: Int = 50) -> [ProgrammeEntity] {
		Array(pairs.prefix(limit)).map { ProgrammeEntity($0.0, $0.1) }
	}

	/// The candidate pool an identifier can resolve against: the schedule of
	/// every guide channel around the asked-for slot is too wide to scan, so
	/// resolution loads the one channel the identifier names.
	@MainActor func entities(for identifiers: [String]) async throws -> [ProgrammeEntity] {
		var out: [ProgrammeEntity] = []
		for identifier in identifiers {
			if let found = try? await SiriLibrary.programme(identifier: identifier) {
				out.append(ProgrammeEntity(found.0, found.1))
			}
		}
		return out
	}

	@MainActor func entities(matching string: String) async throws -> [ProgrammeEntity] {
		let channels = try await SiriLibrary.live()
		let epg = AppModel.shared.library.epg
		let results = await Task.detached { epg.search(string, channels) }.value
		return Self.entities(from: results)
	}

	@MainActor func suggestedEntities() async throws -> [ProgrammeEntity] {
		let channels = try await SiriLibrary.live()
		let prefs = AppModel.shared.prefs
		let epg = AppModel.shared.library.epg
		let ordered = await Task.detached { ChannelDiscovery.suggestions(channels, favorites: prefs.favorites, recent: prefs.recent) }.value
		var pairs: [(Programme, Channel)] = []
		for ch in ordered {
			let guide = epg.nowNext(ch)
			if let now = guide.now { pairs.append((now, ch)) }
			if let next = guide.next { pairs.append((next, ch)) }
		}
		return Self.entities(from: pairs, limit: 20)
	}
}

/// Spoken and written forms of a guide answer. The dialog is what Siri reads
/// aloud (through AirPods or CarPlay there is no screen to re-read), so it is
/// built for listening: fewer results, one sentence each, channel first.
/// The full text stays the value Shortcuts receives.
enum GuideSpeech {
	static func spoken(_ pairs: [(Programme, Channel)], limit: Int = 3) -> String {
		let sentences = pairs.prefix(limit).map { p, ch in
			"\(TVChannelEntity(ch).name). \(p.title). \(Format.dateTime(p.start))."
		}
		return sentences.joined(separator: " ")
	}

	static func full(_ pairs: [(Programme, Channel)], limit: Int = 5) -> String {
		pairs.prefix(limit).map { p, ch in
			"\(TVChannelEntity(ch).name). \(p.title). \(Format.dateTime(p.start)). \(Format.time(p.stop))"
		}.joined(separator: "\n")
	}
}

/// Intent donations: the more the user does in the app, the more Siri
/// suggestions learn what to offer. Donating is fire-and-forget.
enum Donations {
	static func tuned(_ channel: Channel) {
		var intent = TuneChannelIntent()
		intent.channel = TVChannelEntity(channel)
		Task { try? await IntentDonationManager.shared.donate(intent: intent) }
	}

	static func guideOpened(_ channel: Channel) {
		var intent = OpenChannelGuideIntent()
		intent.channel = TVChannelEntity(channel)
		Task { try? await IntentDonationManager.shared.donate(intent: intent) }
	}

	static func recordScheduled(_ programme: Programme, _ channel: Channel) {
		var intent = RecordProgrammeIntent()
		intent.programme = ProgrammeEntity(programme, channel)
		Task { try? await IntentDonationManager.shared.donate(intent: intent) }
	}
}

struct OpenProgrammeIntent: OpenIntent {
	static var title: LocalizedStringResource = "open_programme"
	static var description: IntentDescription? = IntentDescription("open_programme_desc")
	static var openAppWhenRun = true
	@Parameter(title: "programme", description: "programme_parameter_desc") var target: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$target)") }

	@MainActor func perform() async throws -> some IntentResult {
		let (_, ch) = try await SiriLibrary.programme(target)
		let model = AppModel.shared
		model.minimizePlayer()
		model.selectedTab = 1
		model.guidePath = [.channelGuide(ch.key)]
		model.programmeFocus = ProgrammeFocus(channelKey: ch.key, startMs: target.startMs)
		return .result()
	}
}

struct RecordProgrammeIntent: AppIntent {
	static var title: LocalizedStringResource = "record_programme"
	static var description: IntentDescription? = IntentDescription("record_programme_desc")
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<ProgrammeEntity> & ProvidesDialog {
		let (p, ch) = try await SiriLibrary.programme(programme)
		guard p.stop > nowMs() else { throw SiriLibrary.ActionError.message(L("programme_ended")) }
		AppModel.shared.recorder.schedule(ch, title: p.title, start: p.start, end: p.stop)
		let text = L("recording_scheduled", p.title, Format.dateTime(p.start))
		return .result(value: ProgrammeEntity(p, ch), dialog: "\(text)")
	}
}

struct RemindProgrammeIntent: AppIntent {
	static var title: LocalizedStringResource = "remind_programme"
	static var description: IntentDescription? = IntentDescription("remind_programme_desc")
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let (p, ch) = try await SiriLibrary.programme(programme)
		guard p.start > nowMs() else { throw SiriLibrary.ActionError.message(L("programme_started")) }
		let center = UNUserNotificationCenter.current()
		_ = try? await center.requestAuthorization(options: [.alert, .sound])
		let content = UNMutableNotificationContent()
		content.title = p.title
		content.body = "\(TVChannelEntity(ch).name), \(Format.time(p.start))"
		content.sound = .default
		let interval = max(1, TimeInterval(p.start - nowMs()) / 1000)
		let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
		let request = UNNotificationRequest(identifier: "programme-\(p.channelKey)-\(p.start)", content: content, trigger: trigger)
		try await center.add(request)
		let text = L("reminder_set", p.title, Format.dateTime(p.start))
		return .result(dialog: "\(text)")
	}
}
#endif
