#if os(iOS) && SIRI_AI_SDK
import AppIntents

// The iOS 27.3 Siri AI Developer Preview: a ToolIntent is an action Siri can call by itself from a
// natural request, with no fixed phrase. It can call a tool when the app is on screen, when a Live
// Activity runs, in a conversation that already named the app, or when the request names the app.
//
// ToolIntent exists only in the 27.3 SDK. The Build workflow defines SIRI_AI_SDK when the selected
// Xcode's AppIntents interface declares it; older SDKs build this file as nothing and every action
// below stays in Shortcuts and, for the phrases in IPTVShortcuts, in Siri.
//
// `@AppIntent(.tool)` is documented as adding this same conformance, using ToolIntent's availability
// when the type declares none. Extensions keep it in one file and leave the intents building on iOS 18.
// Left out on purpose: OpenTVChannelIntent (TuneChannelIntent is the tool) and the schema intents,
// which the macro refuses because Siri already reaches them.

// Channels
@available(iOS 27.3, *) extension TuneChannelIntent: ToolIntent {}
@available(iOS 27.3, *) extension ListenToChannelIntent: ToolIntent {}
@available(iOS 27.3, *) extension PreviousChannelIntent: ToolIntent {}
@available(iOS 27.3, *) extension FindChannelsIntent: ToolIntent {}
@available(iOS 27.3, *) extension ListCategoriesIntent: ToolIntent {}
@available(iOS 27.3, *) extension ListFavoritesIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetFavoriteIntent: ToolIntent {}
@available(iOS 27.3, *) extension PlayOnDemandIntent: ToolIntent {}

// Guide
@available(iOS 27.3, *) extension WhatsOnChannelIntent: ToolIntent {}
@available(iOS 27.3, *) extension ChannelScheduleIntent: ToolIntent {}
@available(iOS 27.3, *) extension WhatsOnNowIntent: ToolIntent {}
@available(iOS 27.3, *) extension SearchGuideIntent: ToolIntent {}
@available(iOS 27.3, *) extension OpenChannelGuideIntent: ToolIntent {}
@available(iOS 27.3, *) extension OpenProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension ProgrammeDetailsIntent: ToolIntent {}
@available(iOS 27.3, *) extension WatchProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension RemindProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension CancelReminderIntent: ToolIntent {}
@available(iOS 27.3, *) extension DownloadProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension RefreshGuideIntent: ToolIntent {}
@available(iOS 27.3, *) extension RefreshChannelsIntent: ToolIntent {}

// Recording
@available(iOS 27.3, *) extension RecordProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension RecordChannelIntent: ToolIntent {}
@available(iOS 27.3, *) extension ScheduleRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension StopRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension ListRecordingsIntent: ToolIntent {}
@available(iOS 27.3, *) extension CancelScheduledRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension ListSavedRecordingsIntent: ToolIntent {}
@available(iOS 27.3, *) extension PlaySavedRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension DeleteSavedRecordingIntent: ToolIntent {}

// Player
@available(iOS 27.3, *) extension NowPlayingIntent: ToolIntent {}
@available(iOS 27.3, *) extension PauseTVIntent: ToolIntent {}
@available(iOS 27.3, *) extension ResumeTVIntent: ToolIntent {}
@available(iOS 27.3, *) extension StopTVIntent: ToolIntent {}
@available(iOS 27.3, *) extension SkipPlaybackIntent: ToolIntent {}
@available(iOS 27.3, *) extension AudioTrackIntent: ToolIntent {}
@available(iOS 27.3, *) extension SubtitlesIntent: ToolIntent {}
@available(iOS 27.3, *) extension PictureInPictureIntent: ToolIntent {}
@available(iOS 27.3, *) extension CastIntent: ToolIntent {}
@available(iOS 27.3, *) extension StopCastingIntent: ToolIntent {}
@available(iOS 27.3, *) extension SleepTimerIntent: ToolIntent {}
@available(iOS 27.3, *) extension SetPlaybackPreferenceIntent: ToolIntent {}

// Sharing and the rest of the app
@available(iOS 27.3, *) extension StartSharePlayIntent: ToolIntent {}
@available(iOS 27.3, *) extension LeaveSharePlayIntent: ToolIntent {}
@available(iOS 27.3, *) extension ShareNowWatchingIntent: ToolIntent {}
@available(iOS 27.3, *) extension ShareProgrammeIntent: ToolIntent {}
@available(iOS 27.3, *) extension ShareSavedRecordingIntent: ToolIntent {}
@available(iOS 27.3, *) extension AccountStatusIntent: ToolIntent {}
@available(iOS 27.3, *) extension OpenAppScreenIntent: ToolIntent {}
#endif
