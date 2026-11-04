# Apple Intelligence audit, iOS 27.3

Audited 2026-11-03, the day iOS 27.3 beta 1 and the Siri AI Developer Preview shipped, against app 0.7.2.

## What changed in 27.3

Before 27.3, Siri AI reached third-party apps through schemas only. A custom action had no route in, so a TV app could
not expose "what is on later" at all. The preview adds:

- **Tool intents.** `@AppIntent(.tool)` adds a `ToolIntent` conformance. Siri can then call any custom intent from a
  natural request. No fixed phrase. Siri calls a tool when the app is in the foreground, a Live Activity runs, the
  conversation already named the app, or the request names the app.
- **App skills.** `Skills.skillsbundle/Skills/<name>/SKILL.md`, Markdown guidance on combining tools. Advisory, not
  deterministic. Only `name` and `description` frontmatter; body at most 10,000 characters.
- **Video schema domain.** `.video.playContent` with a `@UnionValue` that Apple's template shows with `liveService` and
  `sportsEvent` cases. Documented entities: movie, tvShow, tvSeason, tvEpisode, freeformVideo (`contentType` has `.live`).
- **Entity metadata.** `@Property(title:description:authenticationPolicy:visibility:)`, `GenerableEntity`, `IntentVisibility`.
- **Siri Evaluations** and the Xcode Siri Integration Advisor, for scripted checks on a device.

The preview works with a development-signed build on a device that supports Apple Intelligence, and for internal
TestFlight. It does not work from the App Store or external TestFlight. AltStore installs with a development profile, so this
app's route should qualify. That is inference from Apple's wording, not tested. Not in the EU on iOS. Supported Siri
languages at launch: English, French, Japanese, Korean, Portuguese, Spanish. Traditional Chinese, Norwegian, Turkish and
Vietnamese are announced. Hungarian is not: fixed App Shortcut phrases still matter there.

## Audit findings

Bugs and gaps in what shipped through 0.7.2, all fixed in 0.8.0 unless marked:

1. **No path to Siri AI for anything but play and search.** Only `playAudio` and `searchInApp` were schemas. Fixed in code: 49 tool
   intents, active only on a 27.3 SDK (see Decisions).
2. **Half of Apple's playback use-case group.** `playAudio` shipped without its `IntentValueQuery`. Apple: adopt both to
   reach Siri AI; a macOS 27 release note lists trouble playing content without it. Fixed: `ChannelAudioValueQuery`, which
   also strips Siri's command words from the query and answers a bare "play Accessible IPTV" with recent channels.
3. **"What is on later" did not exist.** `WhatsOnChannelIntent` stops at now and next. Fixed: `ChannelScheduleIntent`.
4. **Programme index went stale.** `ProgrammeSpotlight`'s comment says a guide refresh re-runs it. Nothing called it after a
   guide import, only after a channel load. Fixed at the root: `Library.guideDidImport`.
5. **Siri's search handed to an open screen was lost.** `pendingGuideSearch` is read in `.task`, which does not re-run when
   the search screen is already open. Fixed with `.onChange`.
6. **Smart filter in an unsupported language said "No results".** `availability == .available` is true while the model
   rejects the locale at respond time. Fixed: also checks `supportsLocale()`, so the button hides.
7. **A retried Siri request recorded twice.** `RecordProgrammeIntent` always appended. Fixed: `GuideWindow.alreadyScheduled`.
8. **Sharing a programme sent only its title.** Fixed: title, channel and time. Stream URLs still never leave the app.
9. **Now Playing and reminders carried no entity.** Fixed: `MPNowPlayingInfoPropertyAppEntityIdentifiers` and
   `appEntityIdentifiers`, so "record this" works from the Lock Screen or an announced notification.
10. **Channel rows had no per-row annotation**, only the focused row's activity, so "play the third one" had no target.
    Fixed: `siriChannelRow`.
11. **`.system.open` not adopted.** Fixed: schema open intents for channels and programmes.

Actions added: guide (schedule, on now, details, watch, download, cancel reminder, share, refresh, account, open screen),
channels (find, categories, favourites, set favourite, previous, listen, movies and series), recording (record now, schedule by
time, stop, list, cancel, saved list, play, delete, share), player (now playing, skip, audio track, subtitles, Picture in Picture,
cast, stop casting, sleep timer, settings), sharing (SharePlay start and leave, share what is playing).

## Decisions

- **The 27.3 tool layer builds only on a 27.3 SDK.** `ToolIntent` is missing from Xcode 27.2's SDK and the runner tops out at
  27.2 on the day of writing (`actions/runner-images`, image 20261026). The Build workflow greps the selected SDK's
  AppIntents interface for `protocol ToolIntent` and defines `SIRI_AI_SDK` when found. It prints a notice either way.
  `ourostack/ouro-ui-apple` gates the same type with `canImport(AppIntents, _version: 301.2)`; a grep cannot guess a version
  number wrong. Apple's guide uses the macro. The macro only adds the conformance with `ToolIntent`'s availability, so
  `App/SiriAITools.swift` writes those extensions directly and keeps them behind one gate. **Not yet compiled.** First build on a
  27.3 runner is the check, and it may fail: Apple warns the API may change during the preview.
- **`.video.playContent` not adopted yet.** It is 27.3-only and its macro validates an exact shape (`images: [VideoImage]`,
  `creator: VideoContentCreator?`, `contentType: VideoContentType`, and so on) in a phase a Windows host cannot run. Writing
  150 lines blind, behind a gate nothing compiles, is dead code. Do this first when the runner has the SDK; it replaces the
  radio-station pose of `LiveChannelSchemaEntity`. The tool layer covers watching until then.
- **`@Property(description:)`, `visibility:` not used.** 27.3-only arguments cannot be gated per argument. Add with the video work.
- **Ten App Shortcuts.** Apple's limit, already at ten. Pause, resume and open programme gave up their phrases to what is on
  later, record channel and what am I watching. "Hey Siri, pause" reaches the player through Now Playing. The intents stay.
- **`RecordChannelIntent` opens the app.** The silent keep-alive must start in the foreground.
- **`ListenToChannelIntent` does not.** `AudioPlaybackIntent` runs in the background, and the player already drops the video
  track there. Best fit for a blind user on AirPods with the phone locked.
- **Static snippets, not `SnippetIntent`.** Apple warns Siri AI may show neither dialog nor snippet; entities carry the answer.
  Interactive buttons would need iOS 26 result types and add little to a voice-first flow.
- **Account answer is status and expiry only.** Connection counts and creation dates stay on the Account screen.
- **No Live Activity.** It would let Siri act without the app being named, but needs a widget extension target and a second
  provisioning App ID under AltStore. Worth revisiting after the preview settles.
- **Skipped:** Clock schema for the sleep timer (`SleepTimerIntent` is a tool; a real timer schema needs AlarmKit),
  `addToWatchList` (the app has no watchlist), `RelevantEntities` (workout and now-playing audio contexts).

## Sources

Apple documentation, read through DocC JSON:

1. [Siri AI Developer Preview](https://developer.apple.com/documentation/appintents/siri-ai-developer-preview)
2. [Bringing custom actions and content to Siri](https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri)
3. [Orchestrating complex actions with app skills](https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills)
4. [ToolIntent](https://developer.apple.com/documentation/appintents/toolintent)
5. [AppIntent(_:)](https://developer.apple.com/documentation/appintents/appintent(_:))
6. [AppIntent(_:schema:)](https://developer.apple.com/documentation/appintents/appintent(_:schema:))
7. [AppIntentTraits](https://developer.apple.com/documentation/appintents/appintenttraits)
8. [IntentVisibility](https://developer.apple.com/documentation/appintents/intentvisibility)
9. [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
10. [Video domain](https://developer.apple.com/documentation/appintents/app-schema-domain-video)
11. [playContent](https://developer.apple.com/documentation/appintents/appschema/videointent/playcontent)
12. [freeformVideo](https://developer.apple.com/documentation/appintents/appschema/videoentity/freeformvideo)
13. [tvEpisode](https://developer.apple.com/documentation/appintents/appschema/videoentity/tvepisode)
14. [videoContentType](https://developer.apple.com/documentation/appintents/appschema/videoenum/videocontenttype)
15. [Audio domain](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)
16. [System and in-app search](https://developer.apple.com/documentation/appintents/app-schema-domain-system-and-in-app-search)
17. [system.open](https://developer.apple.com/documentation/appintents/appschema/systemintent/open)
18. [IntentValueQuery](https://developer.apple.com/documentation/appintents/intentvaluequery)
19. [SnippetIntent](https://developer.apple.com/documentation/appintents/snippetintent)
20. [requestConfirmation](https://developer.apple.com/documentation/appintents/appintent/requestconfirmation(conditions:actionname:dialog:))
21. [IntentDialog](https://developer.apple.com/documentation/appintents/intentdialog)
22. [UndoableIntent](https://developer.apple.com/documentation/appintents/undoableintent)
23. [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider)
24. [Siri Evaluations](https://developer.apple.com/documentation/sirievaluations)
25. [App Intents updates](https://developer.apple.com/documentation/updates/appintents)
26. [iOS 27.3 beta release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_3-release-notes)
27. [Xcode 27.3 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_3-release-notes)
28. [Siri AI is now open to all developers](https://developer.apple.com/news/?id=gdk2umrf)
29. [WWDC26 343, Explore advanced App Intents features](https://developer.apple.com/videos/play/wwdc2026/343/), full transcript and code
30. [WWDC26 240, Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/)

News, for timing and availability: [Cult of Mac](https://www.cultofmac.com/news/ios-27-3-beta-siri-ai-audio-intelligence),
[MacRumors](https://www.macrumors.com/2026/11/03/ios-27-3-siri-ai/), [Unite.AI](https://www.unite.ai/apple-opens-siri-ai-developer-preview-for-custom-app-integrations/),
[iClarified](https://www.iclarified.com/103272/apple-opens-siri-ai-app-integrations-to-all-developers).

GitHub, by recency and stars. GitHub's search API rate-limited this session, so results came partly from the Firecrawl
developer index; the star and date sort could not be applied to every feature:

1. [ourostack/ouro-ui-apple](https://github.com/ourostack/ouro-ui-apple/blob/HEAD/Sources/OuroAX/AppIntentsSupport.swift): the only ToolIntent adoption found. Its 27.3 gate; 301.1.16 is Xcode 27.2's AppIntents.
2. [charleswiltgen/axiom, siri-audio-ref](https://github.com/charleswiltgen/axiom/blob/HEAD/axiom-codex/skills/axiom-integration/skills/siri-audio-ref.md): `AudioSearch` criteria, the `@unknown default` trap, Now Playing identifiers, measured against the iOS 27.1 SDK.
3. [charleswiltgen/axiom, siri-audio](https://github.com/charleswiltgen/axiom/blob/HEAD/axiom-codex/skills/axiom-integration/skills/siri-audio.md): green build proves shape, not resolution.
4. [charleswiltgen/axiom, app-schemas-ref](https://github.com/charleswiltgen/axiom/blob/HEAD/axiom-codex/skills/axiom-integration/skills/app-schemas-ref.md): required members of every schema.
5. [charleswiltgen/axiom, app-shortcuts-ref](https://github.com/charleswiltgen/axiom/blob/HEAD/axiom-codex/skills/axiom-integration/skills/app-shortcuts-ref.md)
6. [artemnovichkov/xcode-skills, app-intents-whats-new-27](https://github.com/artemnovichkov/xcode-skills/blob/main/skills/app-intents-whats-new-27/SKILL.md): Apple's own Xcode guidance, treat identifiers and phrases as a public contract.
7. [basedhardware/omi #19767](https://github.com/basedhardware/omi/issues/19767): device evidence on Siri's model filling String parameters, and that phrase slots reject String.
8. [vellum-ai/vellum-assistant #39275](https://github.com/vellum-ai/vellum-assistant/issues/39275): phrases without the app name are dropped silently.
9. [n0an/app-intents-agent-skill](https://github.com/n0an/app-intents-agent-skill): dialog and return-type forms.
10. [rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills/blob/HEAD/skills/apple-intelligence/app-intents/SKILL.md)
11. [BleepingSwift/app-intents-siri-shortcuts](https://github.com/BleepingSwift/app-intents-siri-shortcuts)
12. [erykkruk/flutter_assistant_intents](https://github.com/erykkruk/flutter_assistant_intents)
13. [MateoCentis/ShelfLife](https://github.com/MateoCentis/ShelfLife)
14. [jonzey231/AerioTV](https://github.com/jonzey231/AerioTV): 123 stars, pushed the same day, the closest app (IPTV with Dispatcharr).
15. [brandomoore/Plozz](https://github.com/brandomoore/Plozz), [wattsjs/buffer](https://github.com/wattsjs/buffer), [bilipp/Lume](https://github.com/bilipp/Lume), [mikehouse/Apple-TV-Player](https://github.com/mikehouse/Apple-TV-Player), [bsogulcan/another-iptv-player](https://github.com/bsogulcan/another-iptv-player): the top Swift IPTV repositories by recency and by stars. None has App Intents files in its tree (file names only checked), so there is no prior art for TV actions.
16. [mralexhay/Booky](https://github.com/mralexhay/Booky): 230 stars, top App Intents result by stars, 2022, property query shape.
17. [igorcferreira/TransactionHistory](https://github.com/igorcferreira/TransactionHistory), [junghongseop/AppIntents](https://github.com/junghongseop/AppIntents), [ahmetbostanciklioglu/InteractiveSnippetsSwiftUI](https://github.com/ahmetbostanciklioglu/InteractiveSnippetsSwiftUI): most recently pushed App Intents and SnippetIntent samples. Tree only.

How much was read: Apple items 1 to 29 in full. Item 30, and GitHub items 5 and 9 to 13 and 16 to 17, in excerpt or by search hit only. Per-feature GitHub code search did not complete: the search API returned rate-limit errors, then empty output. A `.video.playContent` or `.tool` adoption beyond item 1 may exist that this did not find.

Earlier adoption notes still apply: `research_notes/Siri channel playback/`, `research_notes/Spotlight and Shortcuts/`.

## Not testable from Windows or in CI

Whether Siri picks these tools for a given phrasing, whether the skills bundle gets compiled by XcodeGen's generated project on a
27.3 SDK (it is a plain resource to Xcode 27.2), and whether AltStore installs qualify for the preview. All need a device on the 27.3 beta.
