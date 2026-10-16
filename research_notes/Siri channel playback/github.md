# GitHub Siri and App Intents implementations

## Which recent and popular repositories were searched?

### Takeaway
Searches ran through GitHub's authenticated REST API on 2026-10-16. Recent examples confirm current patterns; large production projects provide stronger implementation evidence than star counts alone.

### Cited Findings
- Repository searches: `AppIntents language:Swift`, `sort=stars&order=desc`; `AppIntents language:Swift created:>2026-09-01`, `sort=updated&order=desc`; `AppIntents language:Swift`, `sort=updated&order=desc`; `radio ios language:Swift`, `sort=stars&order=desc`. GitHub documents supported repository sorts as stars, forks, help-wanted-issues, updated; `sort=created` is not supported. Newness was assessed using returned `created_at` dates. — [Repository search API](https://docs.github.com/en/rest/search/search#search-repositories)
- Highest-starred broad AppIntents results inspected: [Booky](https://github.com/mralexhay/Booky), 230 stars, created 2022-06-13, updated 2026-10-13; [monterail/intelligence](https://github.com/monterail/intelligence), 40 stars, created 2024-07-31, updated 2026-07-20.
- Recent-created results inspected: [junghongseop/AppIntents](https://github.com/junghongseop/AppIntents), 2 stars, created 2026-10-06, pushed 2026-10-14; [ios-appintents-metadata-build-sample](https://github.com/kntkymt/ios-appintents-metadata-build-sample), 3 stars, created 2026-09-06, pushed 2026-09-06. Newer Wi-Fi, strobe, and Notion-widget matches were screened as unrelated to playback.
- Highest-starred radio results screened: [Swift-Radio-Pro](https://github.com/analogcode/Swift-Radio-Pro), 2,945 stars; [PandoraPlayer](https://github.com/ApplikeySolutions/PandoraPlayer), 1,204 stars; [FRadioPlayer](https://github.com/fethica/FRadioPlayer), 298 stars. GitHub code search found no `AppIntents` in the first two and no `Siri` in Swift-Radio-Pro; those provide no useful intent implementation evidence.
- Relevant production source found through code searches for `AppShortcutsProvider radio language:Swift`, `EnumerableEntityQuery Play language:Swift`, `updateAppShortcutParameters language:Swift`, and `DisplayRepresentation synonyms: language:Swift`: [RetroArch](https://github.com/libretro/RetroArch), 14,351 stars, pushed 2026-10-16; [VLC iOS](https://github.com/videolan/vlc-ios), 1,313 stars, pushed 2026-10-14; [AudioBooth](https://github.com/AudioBooth/AudioBooth), 457 stars, pushed 2026-10-15; [pom11/Radio](https://github.com/pom11/Radio), 9 stars, created 2026-03-17, pushed 2026-10-09; [lutheran.radio](https://github.com/jarilammi/lutheran.radio), 2 stars, pushed 2026-10-16; [radio-swift](https://github.com/synergic777/radio-swift), 4 stars, pushed 2026-01-09.

### Inferences
- Stars rank discovery results, not correctness. Current source and official Apple contracts should determine this fix.

### Gaps
- GitHub `updated_at` can change through repository activity without a code push; `pushed_at` was captured separately for selected implementations.
- Narrow repository-name/description searches `radio Siri language:Swift`, `AppIntents radio language:Swift`, and `Siri IPTV language:Swift` returned no results. Code search was needed to find playback implementations.

## How do working implementations expose dynamic content to Siri?

### Takeaway
Keep the app's existing entity and string matching. Use bounded initial suggestions, refresh parameters after content changes, and provide useful spoken names. Enumeration examples below suit small catalogs and do not establish an initial-vocabulary bypass for this app's potentially 250,000 channels.

### Cited Findings
- AudioBooth's audiobook query conforms to both `EntityStringQuery` and `EnumerableEntityQuery`. It supplies `allEntities()`, `entities(for:)`, `entities(matching:)`, and `suggestedEntities()`. Full enumeration and manual string search coexist in that application's implementation; this does not establish suitability for a large IPTV catalog. — [AudiobookEntity.swift](https://github.com/AudioBooth/AudioBooth/blob/main/PlayerIntents/Sources/PlayerIntents/AudiobookEntity.swift)
- The second-highest broad AppIntents result also adds `EnumerableEntityQuery` to its existing `EntityQuery`; `allEntities()` returns all stored records. This is a small sample, not evidence that enumeration expands Siri's initial phrase vocabulary. — [RepresentableQuery.swift](https://github.com/monterail/intelligence/blob/main/example/ios/Runner/RepresentableQuery.swift)
- RetroArch calls its concrete provider's `updateAppShortcutParameters()` from a content-refresh bridge. It exposes four app-qualified play phrases and separately donates actual successful content launches. — [RetroArchAppShortcuts.swift](https://github.com/libretro/RetroArch/blob/master/pkg/apple/AppIntents/RetroArchAppShortcuts.swift)
- Expo stores a refresh callback specifically so the app target can call its concrete `AppShortcutsProvider.updateAppShortcutParameters()`. — [AppIntentDispatcher.swift](https://github.com/expo/expo/blob/main/packages/expo-app-intents/ios/AppIntentDispatcher.swift)
- Expo passes dynamic entity synonyms as `[LocalizedStringResource]` into `DisplayRepresentation` under an iOS 17 availability guard. Its string matching also searches synonyms. — [DishEntity.swift](https://github.com/expo/expo/blob/main/apps/native-component-list/app-intents/Entities/DishEntity.swift)
- RetroArch strips region and metadata tags for alternate matching, handles ampersand/and variants, and ranks exact titles above partial matches. Its current source deliberately omits the synonyms-bearing display initializer because it supports older SDK/deployment combinations. — [RetroArch entity and matcher](https://github.com/libretro/RetroArch/blob/master/pkg/apple/AppIntents/RetroArchAppShortcuts.swift)
- Booky returns all records as suggestions and supports case-insensitive title/author search, persistent IDs, and entity property queries. — [ShortcutsBookEntity.swift](https://github.com/mralexhay/Booky/blob/main/Shortcuts/ShortcutsBookEntity.swift)
- Recent-created AppIntents lab uses string entity search plus indexed entities for Spotlight; its source phrases remain app-qualified. Indexing is a separate integration from parameter enumeration. — [TaskEntity.swift](https://github.com/junghongseop/AppIntents/blob/master/AppIntents/Features/Tasks/Intents/TaskEntity.swift), [TaskAppShortcuts.swift](https://github.com/junghongseop/AppIntents/blob/master/AppIntents/Features/Tasks/Intents/TaskAppShortcuts.swift)

### Inferences
- Retain `TVChannelQuery: EntityStringQuery`. Do not enumerate all channels: the app can hold 250,000 channels. Use `suggestedEntities()` for initial vocabulary, including all explicit favorites and up to 20 recent channels; fill to a minimum of 20 defaults where needed. Deduplicate entries by stable channel ID.
- Provide an app-only shortcut phrase so Siri can ask for a channel and resolve it through `entities(matching:)` even when the channel was outside initial suggestions.
- Call `IPTVShortcuts.updateAppShortcutParameters()` after live library changes and appropriate startup readiness. Avoid networking or expensive repeat refreshes in UI row rendering.
- Clean provider prefixes/quality suffixes for spoken aliases while preserving canonical channel IDs and display names. Include aliases in both display synonyms and actual query matching.
- Add Play, Tune to, Watch app-qualified phrases and a parameterless phrase that lets Siri ask for the channel. Keep ordinary foreground AppIntent video execution.

### Gaps
- Repositories do not prove Siri recognizes every supplied alias on physical devices. Hardware verification remains necessary.
- No inspected repository proves `allEntities()` bypasses `suggestedEntities()` for initial App Shortcut phrase vocabulary. Apple's framework guidance takes precedence over these examples.
- Do not copy RetroArch's complex fuzzy-matching engine; existing ChannelDiscovery should own minimal normalization.

## What do media applications establish about playback and phrase limits?

### Takeaway
Foreground video playback already matches VLC's model. Broad command coverage needs explicit phrases and channel vocabulary; GitHub examples do not establish support for bare global video commands.

### Cited Findings
- VLC's `PlayVideoIntent` is an ordinary `AppIntent` with `openAppWhenRun = true`; its radio path uses `AudioStartingIntent` and `openAppWhenRun = false`. These are distinct playback use cases. — [VideoIntents.swift](https://github.com/videolan/vlc-ios/blob/master/Sources/App/iOS/VideoIntents.swift), [PlayRadioStationIntent.swift](https://github.com/videolan/vlc-ios/blob/master/Sources/App/iOS/PlayRadioStationIntent.swift)
- VLC radio makes the station parameter optional. If omitted, it requests disambiguation among favorites; one favorite can play directly. — [PlayRadioStationIntent.swift](https://github.com/videolan/vlc-ios/blob/master/Sources/App/iOS/PlayRadioStationIntent.swift)
- Recent macOS Radio uses `EntityStringQuery`, all stored streams as suggestions, a real stream entity parameter, and `openAppWhenRun = true` for starting streams. — [RadioIntents.swift](https://github.com/pom11/Radio/blob/main/Sources/RadioIntents.swift)
- Flutter AppIntents example combines `Summary("Draw [target]")`, an entity parameter, foreground execution, and an app-qualified parameterized phrase. — [ExampleAppIntent.swift](https://github.com/monterail/intelligence/blob/main/example/ios/Runner/ExampleAppIntent.swift)
- Recent metadata sample defines its provider directly in the app target. Its comments report package-discovery trouble with providers placed in multiple bundle roots, but our provider already lives in the app target. — [AppShortcuts.swift](https://github.com/kntkymt/ios-appintents-metadata-build-sample/blob/main/appintentsmetadata/multi-app-intent/AppShortcuts.swift)
- Lutheran Radio explicitly localizes shortcut phrases in the AppShortcuts table, distinct from normal intent text; its source includes app name in every phrase. Its comments claim a multiple-phrase extraction limitation. That claim was not independently verified and conflicts with RetroArch's normal multi-phrase array pattern. — [RadioPlaybackIntents.swift](https://github.com/jarilammi/lutheran.radio/blob/main/Lutheran%20Radio/RadioPlaybackIntents.swift), [RetroArch provider](https://github.com/libretro/RetroArch/blob/master/pkg/apple/AppIntents/RetroArchAppShortcuts.swift)

### Inferences
- Existing video foreground execution needs no new SiriKit media extension merely to fix App Shortcut channel selection.
- Users should receive documented working examples such as “Play Sky Mix in Accessible IPTV”, plus a personally named shortcut for “Play Sky Mix” if desired.
- Do not promise bare “watch Sky Mix” globally based on source examples. Siri routing and personal shortcut names can affect interpretation.
- Verify extracted phrase metadata and localization in the macOS build. Do not duplicate one AppShortcut per synonym based solely on an unverified repository comment.

### Gaps
- No GitHub source establishes a supported global TV-channel SiriKit domain for this app. Official Apple documentation must determine any future domain integration.
- Neither Apple Intelligence availability nor physical Siri speech behavior was verified from Windows.
