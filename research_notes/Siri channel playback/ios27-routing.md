# Siri routing: why "watch sky mix" fails, and what unlocks it

Audited 2026-10-16 against Apple's documentation (App Intents framework, JSON doc API) and
the 0.4.0 build log. App Shortcuts were already correct in shape; the gap is elsewhere.

## What was observed

Spotlight finds a channel (0.4.0 index works). Saying **"watch sky mix"** without the app name
gets "the app doesn't support that" from Siri.

## Rule 1: App Shortcut phrases must contain the app name

`AppShortcutPhraseToken` has exactly one member: `applicationName`. Every phrase in
`IPTVShortcuts` therefore has to read "Watch Sky Mix **in Accessible IPTV**". A bare
"watch sky mix" is not and cannot become an App Shortcut phrase; no amount of extra phrases
changes that. The Help text and the Settings footer already say so.

The only way a bare phrase works today is a shortcut of the user's own (Shortcuts app), which
is why `Settings` now opens the app's Shortcuts page (`ShortcutsLink`).

## Rule 2: Siri AI matches everyday phrasing through *schemas*

Apple's "Integrating your app with Apple Intelligence and Siri AI" states the system uses
schemas as the contract: "Siri AI uses the schemas to match actions and content to phrases
people say in everyday conversation." An app with no schema for an action is not a candidate
for that action, which is what produces "the app doesn't support that".

The matching domain is **audio** (`AppSchema.AudioIntent` / `AudioEntity`), whose playback
use-case group is `.audio.playAudio` plus an `IntentValueQuery` that "returns matching audio".
There is no video or TV domain; `liveRadioStation` is the closest content schema for a live
stream. Verified shapes (Apple's own templates):

```swift
@AppEntity(schema: .audio.liveRadioStation)
struct LiveChannelEntity {
    static let defaultQuery = LiveChannelEntityQuery()   // entities(for:) is the required part
    let id: String
    var title: String
    var providerName: String?
    var displayRepresentation: DisplayRepresentation { … }
}

@AppIntent(schema: .audio.playAudio)
struct PlayChannelIntent: AudioStartingIntent {
    var audioEntity: AudioItem
    var playbackAttributes: Set<PlaybackAttributes>
    var warmupAudioQueueResult: WarmupAudioQueueResult?
    var queueLocation: QueueInsertionLocation?
    func perform() async throws -> some IntentResult { … }
}

@UnionValue enum AudioItem { case liveRadioStation(LiveChannelEntity) }   // keep supported cases
```

`TVChannelEntity` already satisfies most of `liveRadioStation` (`id`, `displayRepresentation`,
a query with `entities(for:)` and `entities(matching:)`); it needs `title` and `providerName`.

## The gate: SDK, not code

| API | Minimum |
| --- | --- |
| `.audio.playAudio`, `.audio.liveRadioStation`, `AudioStartingIntent`, `PlaybackAttributes` | iOS 27.0 |
| `MediaIntents` framework (search/playback request types) | iOS 27.0 |
| `IntentValueQuery` | iOS 26.0 |

The Build workflow's runner (macos-26) tops out at **Xcode 26.6 / iOS 26.5 SDK**, so schema
code cannot compile there — the macros and types do not exist in that SDK, and availability
guards do not help. The runner-images repo also publishes a macOS 27 image with Xcode 27
(`images/macos/xcode-27-arm64-Readme.md`, iOS 27.0 simulator runtime) and Xcode 27 as a public
preview on macos-26. Adopt the schemas with the deployment target still 17.0, guarded by
`@available(iOS 27, *)`, once a runner image provides Xcode 27. Switch the runner first and
verify on `main` (that runs tests and builds without publishing) before tagging.

## Also done in 0.4.1

Every Siri intent now carries `IntentDescription` and parameter descriptions; Apple lists those
alongside phrases as the signals the model matches requests against.

## Known gaps

- App Shortcut phrase *wording* is English for all 14 app languages. Apple localizes phrase text
  through the app's localization tables (`AppShortcuts.strings` per locale); adding 14 languages
  of phrase templates is a separate job.
- `warmupAudioQueue` and the affinity schemas in the same domain are not adopted; only the
  playback use-case group matters for tuning a channel.
