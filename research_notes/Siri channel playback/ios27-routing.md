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

`TVChannelEntity` satisfies most of `liveRadioStation` (`id`, `displayRepresentation`, a query with
`entities(for:)` and `entities(matching:)`) but cannot carry the macro itself: see constraint 1 below.

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
preview on macos-26. The workflow now uses `runs-on: xcode-27` (Xcode 27.0 beta 3, 27A5218g).

## Resolution in 0.4.2

A live report settled it: saying "watch Sky Mix in Accessible IPTV" made Siri AI answer that the
app "doesn't support playing content directly through Siri" — the app was resolved, the action
was not, exactly the schema gap. `App/ChannelAudioSchema.swift` implements the contract:

- `LiveChannelSchemaEntity` — `@AppEntity(schema: .audio.liveRadioStation)`, with `title`,
  `providerName`, `displayRepresentation` and an `EntityStringQuery` that reuses
  `ChannelDiscovery.matching`, so names, groups and numbers resolve as everywhere else.
- `ChannelAudioItem` — a `@UnionValue` with the one supported case, `liveRadioStation`.
- `ChannelPlaybackAttributes` (`shuffle`, `repeat`) and `ChannelQueueInsertionLocation`
  (`next`, `tail`) — `@AppEnum` schemas the parameter list requires; a live channel accepts and
  ignores both.
- `ChannelWarmupResult` — `@AppEntity(schema: .audio.warmupAudioQueueResult)`, required by the
  play intent's property list.
- `PlayChannelAudioIntent` — `@AppIntent(schema: .audio.playAudio)`, `openAppWhenRun` (VLCKit
  renders in app), tuning the channel by its stable identifier hash.

Two constraints learned from a working adoption (holgerkrupp/PodcastClient, `PlayerIntentsExtension`):

1. The schema macro makes the annotated type iOS 27-only, so it cannot go on `TVChannelEntity` —
   every existing intent and shortcut depends on that type. The schema entity mirrors it instead.
2. All of it sits behind `@available(iOS 27.0, *)` and a `#if canImport(MediaIntents)` gate so an
   older SDK still builds the app.

`IntentValueQuery` (the other half of Apple's playback use-case group) is not adopted yet: it
needs the MediaIntents request types, and the entity query already resolves a spoken channel
name. Xcode may warn about the missing half; adopt it if Siri fails to find channels.

## Known gaps

- App Shortcut phrase *wording* is English for all 14 app languages. Apple localizes phrase text
  through the app's localization tables (`AppShortcuts.strings` per locale); adding 14 languages
  of phrase templates is a separate job.
- `warmupAudioQueue` and the affinity schemas in the same domain are not adopted; only the
  playback use-case group matters for tuning a channel.
