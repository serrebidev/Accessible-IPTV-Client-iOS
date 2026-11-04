#if os(iOS)
import AppIntents
import SwiftUI
import UserNotifications
import IPTVCore

@MainActor
extension SiriLibrary {
	static func player() throws -> PlayerController {
		guard let player = AppModel.shared.player else { throw ActionError.message(L("playback_unavailable")) }
		return player
	}

	static func ms(_ date: Date?) -> Int64? { date.map { Int64($0.timeIntervalSince1970 * 1000) } }

	/// The archive address of a finished programme, or the reason there is none.
	static func catchupUrl(_ p: Programme, _ ch: Channel) async throws -> String {
		guard p.stop <= nowMs(), ch.hasCatchup, Catchup.withinWindow(ch, p.start),
			let url = await AppModel.shared.library.catchupUrl(ch, start: p.start, stop: p.stop) else {
			throw ActionError.message(L("no_catchup"))
		}
		return url
	}
}

/// A guide answer on screen: Siri may show this card alongside the spoken dialog. One element
/// per programme, so VoiceOver reads a row as one line.
struct GuideSnippet: View {
	let heading: String
	let rows: [(id: String, title: String, detail: String)]

	init(heading: String, pairs: [(Programme, Channel)]) {
		self.heading = heading
		rows = pairs.prefix(5).map { p, ch in
			(ProgrammeEntity.identifier(p), p.title, Format.sentences([TVChannelEntity(ch).name, GuideSpeech.when(p.start)]))
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
			ForEach(rows, id: \.id) { row in
				VStack(alignment: .leading) {
					Text(row.title)
					Text(row.detail).font(.caption)
				}
				.accessibilityElement(children: .combine)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding()
	}
}

/// "What is on later": the part of the guide the now-and-next answer stops short of.
struct ChannelScheduleIntent: AppIntent {
	static var title: LocalizedStringResource = "channel_schedule"
	static var description: IntentDescription? = IntentDescription("channel_schedule_desc")
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity
	@Parameter(title: "from_time", description: "from_time_desc") var from: Date?
	@Parameter(title: "to_time", description: "to_time_desc") var to: Date?
	static var parameterSummary: some ParameterSummary {
		Summary("\(\.$channel)") {
			\.$from
			\.$to
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ProgrammeEntity]> & ProvidesDialog & ShowsSnippetView {
		let ch = try await SiriLibrary.channel(channel)
		let epg = AppModel.shared.library.epg
		let start = SiriLibrary.ms(from), end = SiriLibrary.ms(to), now = nowMs()
		let window = GuideWindow.range(from: start, to: end, now: now)
		let found = await Task.detached {
			GuideWindow.schedule(epg.schedule(ch, from: window.from, to: window.to), from: start, to: end, now: now, limit: 20)
		}.value
		let pairs = found.map { ($0, ch) }
		let text = found.isEmpty ? L("no_guide_for", channel.name) : GuideSpeech.schedule(channel.name, found)
		return .result(value: ProgrammeQuery.entities(from: pairs), dialog: "\(text)", view: GuideSnippet(heading: channel.name, pairs: pairs))
	}
}

struct WhatsOnNowIntent: AppIntent {
	static var title: LocalizedStringResource = "whats_on_now"
	static var description: IntentDescription? = IntentDescription("whats_on_now_desc")
	@Parameter(title: "groups", description: "category_parameter_desc") var category: String?
	@Parameter(title: "favorites", description: "favorites_only_desc", default: false) var favoritesOnly: Bool
	static var parameterSummary: some ParameterSummary {
		Summary("whats_on_now") {
			\.$category
			\.$favoritesOnly
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ProgrammeEntity]> & ProvidesDialog & ShowsSnippetView {
		let channels = try await SiriLibrary.live()
		let epg = AppModel.shared.library.epg
		let favorites = AppModel.shared.prefs.favorites
		let category = category, favoritesOnly = favoritesOnly
		let pairs: [(Programme, Channel)] = await Task.detached {
			let kept = GuideWindow.filter(epg.onNow(channels), from: nil, to: nil, group: category)
			return favoritesOnly ? kept.filter { favorites.contains($0.1.key) } : GuideWindow.favoritesFirst(kept, favorites: favorites)
		}.value
		let text = pairs.isEmpty ? L(epg.hasGuide ? "no_matches" : "no_guide") : GuideSpeech.spoken(pairs)
		return .result(value: ProgrammeQuery.entities(from: pairs), dialog: "\(text)", view: GuideSnippet(heading: L("whats_on_now"), pairs: pairs))
	}
}

struct ProgrammeDetailsIntent: AppIntent {
	static var title: LocalizedStringResource = "programme_details"
	static var description: IntentDescription? = IntentDescription("programme_details_desc")
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<ProgrammeEntity> & ProvidesDialog {
		let (p, ch) = try await SiriLibrary.programme(programme)
		let entity = ProgrammeEntity(p, ch)
		let text = Format.sentences([entity.title, entity.channelName, GuideSpeech.when(p.start), entity.details])
		return .result(value: entity, dialog: "\(text)")
	}
}

/// Live when it is on now, from the archive when it has ended. Not started yet is an answer.
struct WatchProgrammeIntent: AppIntent {
	static var title: LocalizedStringResource = "watch_programme"
	static var description: IntentDescription? = IntentDescription("watch_programme_desc")
	static var openAppWhenRun = true
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult {
		let (p, ch) = try await SiriLibrary.programme(programme)
		let model = AppModel.shared
		if p.start > nowMs() { throw SiriLibrary.ActionError.message(L("programme_not_started", p.title, GuideSpeech.when(p.start))) }
		if p.stop > nowMs() {
			_ = try await SiriLibrary.tune(TVChannelEntity(ch))
			return .result()
		}
		let url = try await SiriLibrary.catchupUrl(p, ch)
		model.play(url, title: "\(ch.name): \(p.title)", key: ch.key, catchup: true, channel: ch, archiveStart: p.start, archiveStop: p.stop)
		return .result()
	}
}

struct DownloadProgrammeIntent: AppIntent {
	static var title: LocalizedStringResource = "download"
	static var description: IntentDescription? = IntentDescription("download_programme_desc")
	static var openAppWhenRun = true
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let (p, ch) = try await SiriLibrary.programme(programme)
		let url = try await SiriLibrary.catchupUrl(p, ch)
		AppModel.shared.recorder.download(url, name: ch.name, title: p.title, expectMs: p.stop - p.start)
		let text = L("downloading", p.title)
		return .result(dialog: "\(text)")
	}
}

struct CancelReminderIntent: AppIntent {
	static var title: LocalizedStringResource = "cancel_reminder"
	static var description: IntentDescription? = IntentDescription("cancel_reminder_desc")
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let (p, _) = try await SiriLibrary.programme(programme)
		UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [RemindProgrammeIntent.notificationID(p)])
		let text = L("reminder_cancelled", p.title)
		return .result(dialog: "\(text)")
	}
}

struct ShareProgrammeIntent: AppIntent {
	static var title: LocalizedStringResource = "share_programme"
	static var description: IntentDescription? = IntentDescription("share_programme_desc")
	static var openAppWhenRun = true
	@Parameter(title: "programme", description: "programme_parameter_desc") var programme: ProgrammeEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$programme)") }

	@MainActor func perform() async throws -> some IntentResult {
		let (p, ch) = try await SiriLibrary.programme(programme)
		guard ExternalPlayers.share(items: [ProgrammeEntity(p, ch).shareText]) else { throw SiriLibrary.ActionError.message(L("siri_failed")) }
		return .result()
	}
}

struct RefreshGuideIntent: AppIntent {
	static var title: LocalizedStringResource = "import_guide"
	static var description: IntentDescription? = IntentDescription("refresh_guide_desc")
	static var openAppWhenRun = true

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		_ = try await SiriLibrary.live()
		let model = AppModel.shared
		do {
			_ = try await model.library.importGuide()
		} catch {
			throw SiriLibrary.ActionError.message(L("guide_failed", error.localizedDescription))
		}
		model.refresh()
		let text = L("guide_imported")
		return .result(dialog: "\(text)")
	}
}

struct RefreshChannelsIntent: AppIntent {
	static var title: LocalizedStringResource = "refresh_playlists"
	static var description: IntentDescription? = IntentDescription("refresh_channels_desc")
	static var openAppWhenRun = true

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let model = AppModel.shared
		guard !model.prefs.sources.isEmpty else { throw SiriLibrary.ActionError.message(L("no_sources")) }
		let errors = await model.library.load(Library.live, force: true)
		if let first = errors.first, model.library.channels.isEmpty { throw SiriLibrary.ActionError.message(first) }
		model.refresh()
		let text = P("channel_count", model.library.channels.count)
		return .result(dialog: "\(text)")
	}
}

/// Status and expiry only: this answer can reach the system's assistant.
struct AccountStatusIntent: AppIntent {
	static var title: LocalizedStringResource = "account_status_title"
	static var description: IntentDescription? = IntentDescription("account_status_desc")

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let model = AppModel.shared
		var lines: [String] = []
		for source in model.prefs.sources {
			guard let rows = try? await model.library.accountInfo(source), !rows.isEmpty else { continue }
			lines.append(source.name)
			lines += GuideWindow.accountSummary(rows)
		}
		let text = lines.isEmpty ? L("account_unavailable") : Format.sentences(lines)
		return .result(dialog: "\(text)")
	}
}

enum AppScreen: String, AppEnum {
	case browse, onNow, guideSearch, guideChannels, recordings, sources, settings, help

	static var typeDisplayRepresentation: TypeDisplayRepresentation = "open_screen"
	static var caseDisplayRepresentations: [AppScreen: DisplayRepresentation] = [
		.browse: "browse",
		.onNow: "whats_on_now",
		.guideSearch: "search_guide",
		.guideChannels: "channel_guide",
		.recordings: "recordings",
		.sources: "playlists_and_guides",
		.settings: "settings",
		.help: "help"
	]
}

struct OpenAppScreenIntent: AppIntent {
	static var title: LocalizedStringResource = "open_screen"
	static var description: IntentDescription? = IntentDescription("open_screen_desc")
	static var openAppWhenRun = true
	@Parameter(title: "open_screen", description: "open_screen_desc") var screen: AppScreen
	static var parameterSummary: some ParameterSummary { Summary("\(\.$screen)") }

	@MainActor func perform() async throws -> some IntentResult {
		let model = AppModel.shared
		model.minimizePlayer()
		switch screen {
		case .browse: model.selectedTab = 0; model.path = []
		case .onNow: model.selectedTab = 1; model.guidePath = [.onNow]
		case .guideSearch: model.selectedTab = 1; model.guidePath = [.guideSearch]
		case .guideChannels: model.selectedTab = 1; model.guidePath = [.guideChannels]
		case .recordings: model.selectedTab = 2
		case .sources: model.selectedTab = 0; model.path = [.sources]
		case .settings: model.selectedTab = 3
		case .help: model.selectedTab = 0; model.path = [.help]
		}
		return .result()
	}
}
#endif
