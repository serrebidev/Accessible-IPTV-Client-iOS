#if os(iOS)
import AppIntents
import CoreTransferable
import IPTVCore
import UniformTypeIdentifiers

/// A recording waiting for its start time.
struct ScheduledRecordingEntity: AppEntity {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "schedule_recording"
	static var defaultQuery = ScheduledRecordingQuery()
	let id: String
	let scheduleId: Int
	@Property(title: "programme") var title: String
	@Property(title: "channel") var channelName: String
	@Property(title: "programme_start") var start: Date
	@Property(title: "programme_end") var end: Date

	init(_ s: Recording.Scheduled) {
		// Plain stored properties first, as in ProgrammeEntity.
		id = String(s.id)
		scheduleId = s.id
		let publicName = ChannelDiscovery.publicText(s.name)
		title = s.title.isEmpty ? publicName : ChannelDiscovery.publicText(s.title)
		channelName = publicName
		start = Date(timeIntervalSince1970: Double(s.start) / 1000)
		end = Date(timeIntervalSince1970: Double(s.end) / 1000)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(title)", subtitle: "\(Format.sentences([channelName, GuideSpeech.when(Int64(start.timeIntervalSince1970 * 1000))]))")
	}
}

struct ScheduledRecordingQuery: EntityStringQuery {
	@MainActor func entities(for identifiers: [String]) async throws -> [ScheduledRecordingEntity] {
		let all = AppModel.shared.recorder.scheduled.map(ScheduledRecordingEntity.init)
		return identifiers.compactMap { id in all.first { $0.id == id } }
	}

	@MainActor func entities(matching string: String) async throws -> [ScheduledRecordingEntity] {
		AppModel.shared.recorder.scheduled.map(ScheduledRecordingEntity.init).filter {
			$0.title.localizedCaseInsensitiveContains(string) || $0.channelName.localizedCaseInsensitiveContains(string)
		}
	}

	@MainActor func suggestedEntities() async throws -> [ScheduledRecordingEntity] {
		AppModel.shared.recorder.scheduled.map(ScheduledRecordingEntity.init)
	}
}

/// A finished recording or download on disk. Transfers as the file, so another app can take it.
struct SavedRecordingEntity: AppEntity, Transferable {
	static var typeDisplayRepresentation: TypeDisplayRepresentation = "recordings"
	static var defaultQuery = SavedRecordingQuery()
	let id: String
	let url: URL
	@Property(title: "programme") var name: String
	@Property(title: "programme_start") var added: Date

	init(_ saved: RecorderCenter.Saved) {
		id = saved.name
		url = saved.url
		name = saved.name
		added = Date(timeIntervalSince1970: Double(saved.added) / 1000)
	}

	var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(Format.dateTime(Int64(added.timeIntervalSince1970 * 1000)))")
	}

	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(exportedContentType: .mpeg2TransportStream) { SentTransferredFile($0.url) }
		ProxyRepresentation(exporting: \.name)
	}
}

struct SavedRecordingQuery: EntityStringQuery {
	@MainActor func entities(for identifiers: [String]) async throws -> [SavedRecordingEntity] {
		let all = AppModel.shared.recorder.saved().map(SavedRecordingEntity.init)
		return identifiers.compactMap { id in all.first { $0.id == id } }
	}

	@MainActor func entities(matching string: String) async throws -> [SavedRecordingEntity] {
		AppModel.shared.recorder.saved().map(SavedRecordingEntity.init).filter { $0.name.localizedCaseInsensitiveContains(string) }
	}

	@MainActor func suggestedEntities() async throws -> [SavedRecordingEntity] {
		Array(AppModel.shared.recorder.saved().prefix(20)).map(SavedRecordingEntity.init)
	}
}

@MainActor
extension SiriLibrary {
	static func file(_ entity: SavedRecordingEntity) throws -> RecorderCenter.Saved {
		guard let saved = AppModel.shared.recorder.saved().first(where: { $0.name == entity.id }) else {
			throw ActionError.message(L("recording_missing"))
		}
		return saved
	}
}

/// A recording keeps the app awake with its silent sound, and iOS lets that start only from
/// the foreground, so an action that begins one opens the app.
struct RecordChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "record_channel"
	static var description: IntentDescription? = IntentDescription("record_channel_desc")
	static var openAppWhenRun = true
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity
	@Parameter(title: "minutes", description: "record_minutes_desc") var minutes: Int?
	static var parameterSummary: some ParameterSummary {
		Summary("\(\.$channel)") {
			\.$minutes
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<TVChannelEntity> & ProvidesDialog {
		let ch = try await SiriLibrary.channel(channel)
		let model = AppModel.shared
		let end = minutes.map { nowMs() + Int64(max(1, $0)) * 60_000 } ?? 0
		model.recorder.start(ch, title: model.library.epg.nowNext(ch).now?.title ?? "", endMs: end)
		let text = L("recording_channel", channel.name)
		return .result(value: TVChannelEntity(ch), dialog: "\(text)")
	}
}

/// A recording by clock time, for when the guide has no entry to pick.
struct ScheduleRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "schedule_recording"
	static var description: IntentDescription? = IntentDescription("schedule_recording_desc")
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity
	@Parameter(title: "from_time", description: "from_time_desc") var start: Date
	@Parameter(title: "to_time", description: "to_time_desc") var end: Date?
	@Parameter(title: "programme", description: "record_title_desc") var name: String?
	static var parameterSummary: some ParameterSummary {
		Summary("\(\.$channel), \(\.$start)") {
			\.$end
			\.$name
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let ch = try await SiriLibrary.channel(channel)
		let model = AppModel.shared
		guard let window = GuideWindow.recording(start: SiriLibrary.ms(start) ?? 0, end: SiriLibrary.ms(end), now: nowMs()) else {
			throw SiriLibrary.ActionError.message(L("recording_time_invalid"))
		}
		let guide = model.library.epg.schedule(ch, from: window.start, to: window.start + 1).first?.title
		let label = name ?? guide ?? ""
		let text = L("recording_scheduled", label.isEmpty ? channel.name : label, Format.dateTime(window.start))
		if !GuideWindow.alreadyScheduled(model.recorder.scheduled, channelKey: ch.key, start: window.start, end: window.end) {
			model.recorder.schedule(ch, title: label, start: window.start, end: window.end)
		}
		return .result(dialog: "\(text)")
	}
}

struct StopRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "stop_recording_channel"
	static var description: IntentDescription? = IntentDescription("stop_recording_desc")
	@Parameter(title: "channel", description: "channel_any_desc") var channel: TVChannelEntity?
	static var parameterSummary: some ParameterSummary {
		Summary("stop_recording_channel") {
			\.$channel
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let recorder = AppModel.shared.recorder
		if let channel {
			let ch = try await SiriLibrary.channel(channel)
			guard recorder.isRecording(ch.key) else { throw SiriLibrary.ActionError.message(L("no_recording_running")) }
			recorder.stop(ch.key)
			let text = L("recording_stopped", channel.name)
			return .result(dialog: "\(text)")
		}
		guard !recorder.active.isEmpty else { throw SiriLibrary.ActionError.message(L("no_recording_running")) }
		recorder.stopAll()
		let text = L("recordings_stopped")
		return .result(dialog: "\(text)")
	}
}

struct ListRecordingsIntent: AppIntent {
	static var title: LocalizedStringResource = "recordings"
	static var description: IntentDescription? = IntentDescription("list_recordings_desc")

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ScheduledRecordingEntity]> & ProvidesDialog {
		let recorder = AppModel.shared.recorder
		let scheduled = recorder.scheduled.map(ScheduledRecordingEntity.init)
		let upcoming = scheduled.prefix(3).map { "\($0.title), \(GuideSpeech.when(Int64($0.start.timeIntervalSince1970 * 1000)))" }
		let text = Format.sentences([L("recordings_heading", recorder.active.count, scheduled.count, recorder.saved().count)] + upcoming)
		return .result(value: scheduled, dialog: "\(text)")
	}
}

struct CancelScheduledRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "cancel_recording"
	static var description: IntentDescription? = IntentDescription("cancel_recording_desc")
	@Parameter(title: "schedule_recording", description: "recording_parameter_desc") var recording: ScheduledRecordingEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$recording)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let question = L("cancel_recording_q", recording.title)
		try await requestConfirmation(dialog: "\(question)")
		AppModel.shared.recorder.cancel(recording.scheduleId)
		let text = L("recording_cancelled")
		return .result(dialog: "\(text)")
	}
}

struct ListSavedRecordingsIntent: AppIntent {
	static var title: LocalizedStringResource = "saved_recordings"
	static var description: IntentDescription? = IntentDescription("saved_recordings_desc")

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[SavedRecordingEntity]> & ProvidesDialog {
		let saved = AppModel.shared.recorder.saved().map(SavedRecordingEntity.init)
		let text = saved.isEmpty ? L("no_matches") : Format.sentences(saved.prefix(5).map(\.name))
		return .result(value: saved, dialog: "\(text)")
	}
}

struct PlaySavedRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "play_recording"
	static var description: IntentDescription? = IntentDescription("play_recording_desc")
	static var openAppWhenRun = true
	@Parameter(title: "recordings", description: "recording_parameter_desc") var recording: SavedRecordingEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$recording)") }

	@MainActor func perform() async throws -> some IntentResult {
		let saved = try SiriLibrary.file(recording)
		AppModel.shared.play(saved.url.absoluteString, title: saved.name, key: "", catchup: true)
		return .result()
	}
}

struct DeleteSavedRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "delete_recording"
	static var description: IntentDescription? = IntentDescription("delete_recording_desc")
	@Parameter(title: "recordings", description: "recording_parameter_desc") var recording: SavedRecordingEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$recording)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let saved = try SiriLibrary.file(recording)
		let question = L("delete_recording_q", saved.name)
		try await requestConfirmation(dialog: "\(question)")
		AppModel.shared.recorder.delete(saved)
		let text = L("recording_deleted", saved.name)
		return .result(dialog: "\(text)")
	}
}

struct ShareSavedRecordingIntent: AppIntent {
	static var title: LocalizedStringResource = "share_recording"
	static var description: IntentDescription? = IntentDescription("share_recording_desc")
	static var openAppWhenRun = true
	@Parameter(title: "recordings", description: "recording_parameter_desc") var recording: SavedRecordingEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$recording)") }

	@MainActor func perform() async throws -> some IntentResult {
		guard ExternalPlayers.share(items: [try SiriLibrary.file(recording).url]) else { throw SiriLibrary.ActionError.message(L("siri_failed")) }
		return .result()
	}
}
#endif
