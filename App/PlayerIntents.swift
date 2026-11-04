#if os(iOS)
import AppIntents
import IPTVCore

/// Names read out, the same way in every list answer.
private func spokenList(_ names: [String], limit: Int = 8) -> String { Format.sentences(Array(names.prefix(limit))) }

/// Answers "find channels" with a value later steps and follow-ups can use. Full filtering and
/// sorting stays on the Find Channels action the entity query generates in Shortcuts.
struct FindChannelsIntent: AppIntent {
	static var title: LocalizedStringResource = "find_channels"
	static var description: IntentDescription? = IntentDescription("find_channels_desc")
	@Parameter(title: "search", description: "name_search_desc") var query: String?
	@Parameter(title: "groups", description: "category_parameter_desc") var category: String?
	static var parameterSummary: some ParameterSummary {
		Summary("find_channels") {
			\.$query
			\.$category
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[TVChannelEntity]> & ProvidesDialog {
		let channels = try await SiriLibrary.live()
		let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", category = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let found: [Channel] = await Task.detached {
			let pool = category.isEmpty ? channels : channels.filter { $0.group.localizedCaseInsensitiveContains(category) }
			return query.isEmpty ? Array(pool.prefix(20)) : ChannelDiscovery.resolve(pool, query)
		}.value
		let entities = found.map(TVChannelEntity.init)
		let text = entities.isEmpty ? L("no_matches") : spokenList(entities.map(\.name))
		return .result(value: entities, dialog: "\(text)")
	}
}

struct ListCategoriesIntent: AppIntent {
	static var title: LocalizedStringResource = "groups"
	static var description: IntentDescription? = IntentDescription("list_categories_desc")

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
		_ = try await SiriLibrary.live()
		let names = AppModel.shared.library.groupSummary(Library.live).map(\.name).map(ChannelDiscovery.publicText).filter { !$0.isEmpty }
		let text = names.isEmpty ? L("no_matches") : spokenList(names, limit: 12)
		return .result(value: names, dialog: "\(text)")
	}
}

struct ListFavoritesIntent: AppIntent {
	static var title: LocalizedStringResource = "favorites"
	static var description: IntentDescription? = IntentDescription("list_favorites_desc")

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[TVChannelEntity]> & ProvidesDialog {
		let channels = try await SiriLibrary.live()
		let favorites = AppModel.shared.prefs.favorites
		let epg = AppModel.shared.library.epg
		let found = await Task.detached { channels.filter { favorites.contains($0.key) } }.value
		let lines = found.prefix(8).map { ch -> String in
			let name = TVChannelEntity(ch).name
			return epg.nowNext(ch).now.map { "\(name): \($0.title)" } ?? name
		}
		let text = lines.isEmpty ? L("no_matches") : spokenList(lines)
		return .result(value: found.map(TVChannelEntity.init), dialog: "\(text)")
	}
}

struct SetFavoriteIntent: AppIntent {
	static var title: LocalizedStringResource = "set_favorite"
	static var description: IntentDescription? = IntentDescription("set_favorite_desc")
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity
	@Parameter(title: "favorites", description: "on_off_desc", default: true) var isFavorite: Bool
	static var parameterSummary: some ParameterSummary {
		Summary("\(\.$channel)") {
			\.$isFavorite
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<TVChannelEntity> & ProvidesDialog {
		let ch = try await SiriLibrary.channel(channel)
		let model = AppModel.shared
		if isFavorite { model.prefs.favorites.insert(ch.key) } else { model.prefs.favorites.remove(ch.key) }
		IPTVShortcuts.updateAppShortcutParameters()
		model.refresh()
		let text = L(isFavorite ? "added_favorite" : "removed_favorite", channel.name)
		return .result(value: TVChannelEntity(ch), dialog: "\(text)")
	}
}

struct PreviousChannelIntent: AppIntent {
	static var title: LocalizedStringResource = "previous_channel"
	static var description: IntentDescription? = IntentDescription("previous_channel_desc")
	static var openAppWhenRun = true

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<TVChannelEntity> {
		let channels = try await SiriLibrary.live()
		// Index the saved keys, as the app's own Previous channel does: [1] is the one before.
		let recent = AppModel.shared.prefs.recent
		guard recent.count > 1, let previous = channels.first(where: { $0.key == recent[1] }) else {
			throw SiriLibrary.ActionError.message(L("no_previous"))
		}
		return .result(value: try await SiriLibrary.tune(TVChannelEntity(previous)))
	}
}

/// Tunes without bringing the app forward: sound with the screen locked or from AirPods.
/// The app's background audio mode already drops the video track there.
struct ListenToChannelIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "listen_channel"
	static var description: IntentDescription? = IntentDescription("listen_channel_desc")
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity
	static var parameterSummary: some ParameterSummary { Summary("\(\.$channel)") }

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<TVChannelEntity> {
		.result(value: try await SiriLibrary.tune(channel, internalPlayer: true))
	}
}

/// Movies and series, which are not channels and so are not in the channel entity.
struct PlayOnDemandIntent: AppIntent {
	static var title: LocalizedStringResource = "play_on_demand"
	static var description: IntentDescription? = IntentDescription("play_on_demand_desc")
	static var openAppWhenRun = true
	@Parameter(title: "search", description: "name_search_desc") var name: String
	static var parameterSummary: some ParameterSummary { Summary("\(\.$name)") }

	@MainActor func perform() async throws -> some IntentResult {
		let model = AppModel.shared, library = model.library
		guard !model.prefs.sources.isEmpty else { throw SiriLibrary.ActionError.message(L("no_sources")) }
		let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
		for section in [Library.movies, Library.series] {
			if !library.isLoaded(section) { _ = await library.load(section, force: false) }
			if let match = await Task.detached(operation: { library.search(section, wanted).first }).value {
				model.minimizePlayer()
				model.selectedTab = 0
				model.open(match)
				return .result()
			}
		}
		throw SiriLibrary.ActionError.message(L("no_matches"))
	}
}

struct NowPlayingIntent: AppIntent {
	static var title: LocalizedStringResource = "now_watching"
	static var description: IntentDescription? = IntentDescription("now_watching_desc")

	@MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ProgrammeEntity]> & ProvidesDialog {
		let player = try SiriLibrary.player()
		let programme = player.currentProgramme.flatMap { p in player.channel.map { ProgrammeEntity(p, $0) } }
		let text = player.nowPlaying.isEmpty ? player.request.title : player.nowPlaying
		return .result(value: programme.map { [$0] } ?? [], dialog: "\(text)")
	}
}

struct SkipPlaybackIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "skip_playback"
	static var description: IntentDescription? = IntentDescription("skip_playback_desc")
	@Parameter(title: "seconds", description: "seconds_desc") var seconds: Int
	static var parameterSummary: some ParameterSummary { Summary("\(\.$seconds)") }

	@MainActor func perform() async throws -> some IntentResult {
		guard try SiriLibrary.player().skip(by: Double(seconds)) else { throw SiriLibrary.ActionError.message(L("cannot_skip")) }
		return .result()
	}
}

struct AudioTrackIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "audio_track"
	static var description: IntentDescription? = IntentDescription("audio_track_desc")
	@Parameter(title: "audio_track", description: "name_search_desc") var name: String?
	static var parameterSummary: some ParameterSummary {
		Summary("audio_track") {
			\.$name
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let player = try SiriLibrary.player()
		let tracks = player.audioTracks()
		if let name, let match = tracks.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
			player.selectAudio(match)
			let text = L("audio_track_set", match.name)
			return .result(dialog: "\(text)")
		}
		let text = tracks.isEmpty ? L("no_matches") : spokenList(tracks.map(\.name))
		return .result(dialog: "\(text)")
	}
}

/// Asking counts as opting in for this session, the same as picking a track in the player.
struct SubtitlesIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "subtitles"
	static var description: IntentDescription? = IntentDescription("subtitles_intent_desc")
	@Parameter(title: "subtitles", description: "on_off_desc", default: true) var enabled: Bool
	@Parameter(title: "audio_track", description: "name_search_desc") var track: String?
	static var parameterSummary: some ParameterSummary {
		Summary("subtitles") {
			\.$enabled
			\.$track
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let player = try SiriLibrary.player()
		guard enabled else {
			player.selectSubtitle(nil)
			let text = L("subtitles_set", L("subtitles_off"))
			return .result(dialog: "\(text)")
		}
		let tracks = player.textTracks()
		guard let choice = track.flatMap({ wanted in tracks.first { $0.name.localizedCaseInsensitiveContains(wanted) } }) ?? tracks.first else {
			throw SiriLibrary.ActionError.message(L("no_subtitles"))
		}
		player.selectSubtitle(choice)
		let text = L("subtitles_set", choice.name)
		return .result(dialog: "\(text)")
	}
}

struct PictureInPictureIntent: AppIntent {
	static var title: LocalizedStringResource = "picture_in_picture"
	static var description: IntentDescription? = IntentDescription("pip_intent_desc")
	static var openAppWhenRun = true

	@MainActor func perform() async throws -> some IntentResult {
		let player = try SiriLibrary.player()
		guard player.pipStartable else { throw SiriLibrary.ActionError.message(L("pip_unavailable")) }
		player.startPiP()
		return .result()
	}
}

struct CastIntent: AppIntent {
	static var title: LocalizedStringResource = "cast"
	static var description: IntentDescription? = IntentDescription("cast_intent_desc")
	@Parameter(title: "cast", description: "name_search_desc") var device: String?
	static var parameterSummary: some ParameterSummary {
		Summary("cast") {
			\.$device
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let player = try SiriLibrary.player()
		let found = player.renderers()
		if let device, let match = found.first(where: { $0.name.localizedCaseInsensitiveContains(device) }) {
			player.cast(to: match)
			let text = L("casting_to", match.name)
			return .result(dialog: "\(text)")
		}
		let text = found.isEmpty ? L("cast_none") : spokenList(found.map(\.name))
		return .result(dialog: "\(text)")
	}
}

struct StopCastingIntent: AppIntent {
	static var title: LocalizedStringResource = "stop_casting"
	static var description: IntentDescription? = IntentDescription("stop_casting_desc")

	@MainActor func perform() async throws -> some IntentResult {
		let player = try SiriLibrary.player()
		if player.casting != nil || player.isRelayingVideo { player.cast(to: nil) }
		return .result()
	}
}

struct SleepTimerIntent: AudioPlaybackIntent {
	static var title: LocalizedStringResource = "sleep_timer"
	static var description: IntentDescription? = IntentDescription("sleep_timer_desc")
	@Parameter(title: "minutes", description: "sleep_minutes_desc") var minutes: Int
	static var parameterSummary: some ParameterSummary { Summary("\(\.$minutes)") }

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		AppModel.shared.setSleepTimer(minutes: minutes)
		let text = minutes > 0 ? L("sleep_timer_set", minutes) : L("sleep_timer_off")
		return .result(dialog: "\(text)")
	}
}

enum PlaybackPreference: String, AppEnum {
	case subtitles, speakSubtitles, audioDescription

	static var typeDisplayRepresentation: TypeDisplayRepresentation = "settings"
	static var caseDisplayRepresentations: [PlaybackPreference: DisplayRepresentation] = [
		.subtitles: "subtitles_enabled",
		.speakSubtitles: "speak_subtitles",
		.audioDescription: "prefer_ad"
	]
}

struct SetPlaybackPreferenceIntent: AppIntent {
	static var title: LocalizedStringResource = "set_preference"
	static var description: IntentDescription? = IntentDescription("set_preference_desc")
	@Parameter(title: "settings", description: "preference_desc") var preference: PlaybackPreference
	@Parameter(title: "set_preference", description: "on_off_desc") var enabled: Bool
	static var parameterSummary: some ParameterSummary {
		Summary("\(\.$preference)") {
			\.$enabled
		}
	}

	@MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
		let prefs = AppModel.shared.prefs
		let name: String
		switch preference {
		case .subtitles: prefs.subtitlesEnabled = enabled; name = L("subtitles_enabled")
		case .speakSubtitles: prefs.speakSubtitles = enabled; name = L("speak_subtitles")
		case .audioDescription: prefs.preferAudioDescription = enabled; name = L("prefer_ad")
		}
		let text = L(enabled ? "setting_on" : "setting_off", name)
		return .result(dialog: "\(text)")
	}
}

/// Tunes first when a channel is named, then starts the same activity as the player's button.
/// iOS shows its own sheet when there is no call to share into.
struct StartSharePlayIntent: AppIntent {
	static var title: LocalizedStringResource = "shareplay_start"
	static var description: IntentDescription? = IntentDescription("shareplay_start_desc")
	static var openAppWhenRun = true
	@Parameter(title: "channel", description: "channel_parameter_desc") var channel: TVChannelEntity?
	static var parameterSummary: some ParameterSummary {
		Summary("shareplay_start") {
			\.$channel
		}
	}

	@MainActor func perform() async throws -> some IntentResult {
		if let channel { _ = try await SiriLibrary.tune(channel) }
		SharePlayCenter.shared.start(try SiriLibrary.player())
		return .result()
	}
}

struct LeaveSharePlayIntent: AppIntent {
	static var title: LocalizedStringResource = "shareplay_leave"
	static var description: IntentDescription? = IntentDescription("shareplay_leave_desc")

	@MainActor func perform() async throws -> some IntentResult {
		SharePlayCenter.shared.leave()
		return .result()
	}
}

/// Channel and programme names only: stream addresses carry logins and never leave the app.
struct ShareNowWatchingIntent: AppIntent {
	static var title: LocalizedStringResource = "share_now_watching"
	static var description: IntentDescription? = IntentDescription("share_now_watching_desc")
	static var openAppWhenRun = true

	@MainActor func perform() async throws -> some IntentResult {
		let player = try SiriLibrary.player()
		let text = player.nowPlaying.isEmpty ? player.request.title : player.nowPlaying
		guard ExternalPlayers.share(items: [ChannelDiscovery.publicText(text)]) else { throw SiriLibrary.ActionError.message(L("siri_failed")) }
		return .result()
	}
}
#endif
