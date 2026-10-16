# Apple Siri channel playback

Research date: 2026-10-16. Product code inspected read-only: `App/AppIntents.swift`. Sources below were opened and their substantive content inspected, using Apple DocC JSON when the ordinary documentation URL returned a JavaScript shell. Firecrawl successfully read the WWDC22 transcript and two API pages. Search snippets alone were not treated as evidence.

## What makes a channel name work in a Siri phrase?

### Takeaway
Initial App Shortcut utterances use a vocabulary published ahead of time. `EntityStringQuery` supports searching a dynamic catalog, but does not itself publish every catalog name as an initial-utterance parameter.

### Cited findings
- Parameterized App Shortcuts combine each phrase with the entities returned by `suggestedEntities()`. The phrase uses each entity’s display title. Call `updateAppShortcutParameters()` when the available values change. Add a phrase without the parameter so Siri can ask for it. Initial phrases cannot contain an arbitrary free-form string. — [Implement App Shortcuts with App Intents, WWDC22](https://developer.apple.com/videos/play/wwdc2022/10170/)
- All trigger phrases must contain the app name or a declared app-name synonym. iOS17 adds entity display synonyms; these work in initial trigger phrases and follow-up prompts. Refresh App Shortcut parameters when synonyms change. — [Spotlight your app with App Shortcuts, WWDC23](https://developer.apple.com/videos/play/wwdc2023/10102/)
- Apple’s newer introduction still generates an App Shortcut for each suggested entity by calling the provider’s update method. It separately describes string queries as a way to search entities while configuring an intent. — [Get to know App Intents, WWDC25](https://developer.apple.com/videos/play/wwdc2025/244/)
- `EntityStringQuery` accepts arbitrary string input used to find entity instances by the names people use. Available since iOS16. — [EntityStringQuery](https://developer.apple.com/documentation/appintents/entitystringquery)
- `DisplayRepresentation.synonyms` accepts localized alternate names for the specific entity. Available since iOS17. — [DisplayRepresentation.synonyms](https://developer.apple.com/documentation/appintents/displayrepresentation/synonyms)
- Apple’s trail sample uses favorite trails as suggestions and a string query for the wider searchable catalog. It refreshes parameters at application startup. — [Accelerating app interactions with App Intents](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents/)

### Inferences
- Existing `Play <channel> in <app>` phrase cannot reliably recognize a channel outside its twenty suggested entities, even when the string matcher would find it.
- A provider title such as `UK: Sky Mix HD` needs a clean spoken alias such as `Sky Mix`; exposing only the decorated title reduces recognizability.
- Add explicit Play, Tune to, and Watch variants, plus a parameter-free launch phrase. Keep the entity parameter required so Siri asks for a channel before playback.
- Calls to update parameters should follow catalog changes and relevant favorite/recent changes. The coordinator reports existing `MainView` catalog-load refreshes; the refresh mechanism is therefore not wholly missing.

### Gaps
- No public Apple guarantee found that every suggested entity will always be recognized, nor a documented numeric maximum for suggestions.
- No evidence found that current `EntityStringQuery` invokes a free-form catalog search for every unsupported initial utterance on iOS17.

## How should this scale to a 250,000-channel playlist?

### Takeaway
Keep a bounded initial vocabulary and a searchable full catalog. Do not enumerate 250,000 entities solely to expand Siri grammar.

### Cited findings
- `EnumerableEntityQuery` is intended for relatively small entity lists. Apple explicitly recommends `EntityPropertyQuery` when there may be many thousands of entities. Enumeration generates a Find action and automatic filtering; the documentation does not claim it publishes initial Siri phrase vocabulary. — [EnumerableEntityQuery](https://developer.apple.com/documentation/appintents/enumerableentityquery)
- `AppShortcutOptionsCollection` represents a collection of parameter options using a `DynamicOptionsProvider`. Available since iOS17. — [AppShortcutOptionsCollection](https://developer.apple.com/documentation/appintents/appshortcutoptionscollection)
- `AppShortcutParameterPresentation` describes presentation for the provided App Shortcut parameter. Its initializer accepts option collections; neither page documents a free-form initial-utterance recognition bypass. — [AppShortcutParameterPresentation](https://developer.apple.com/documentation/appintents/appshortcutparameterpresentation), [initializer](https://developer.apple.com/documentation/appintents/appshortcutparameterpresentation/init(for:summary:optionscollections:))
- Apple’s official sample retains `EntityStringQuery` for large catalogs and recommends ordinary suggestions for small static lists. — [Soup Chef with App Intents](https://developer.apple.com/documentation/sirikit/soup-chef-with-app-intents-migrating-custom-intents)

### Inferences
- Preserve full-catalog string matching. Publish useful favorites/recent channels with spoken synonyms. A parameter-free phrase provides the reliable entry point for names not yet published.
- Replacing `EntityStringQuery` with enumeration is both a scalability regression and an unsupported attempt to fix initial recognition.
- Enlarging the suggestion limit moderately can improve coverage, but must not be described as complete 250,000-channel natural-language support.

### Gaps
- No official evidence found that separate options collections can expose an unlimited searchable initial vocabulary while retaining a small `suggestedEntities()` list.
- Real iPhone Siri invocation remains necessary to verify recognition, indexing latency, and ambiguous names. Windows tests cannot prove these behaviors.

## Can Apple Intelligence or SiriKit enable bare Play, Tune to, or Watch commands?

### Takeaway
App Shortcuts require the app name. A personally named shortcut can provide the exact bare phrase. Current natural media domains target audio, not arbitrary live TV channel tuning.

### Cited findings
- People can run any shortcut in their collection by saying its name. A shortcut opening an app requires unlocking a locked device. — [Use Siri to run shortcuts with your voice](https://support.apple.com/en-nz/guide/shortcuts/apd07c25bb38/ios)
- SiriKit’s Media domain controls audio directly. Watching media is described through shortcuts. This distinction matters despite `INMediaItem` being capable of describing a TV show. — [SiriKit Media](https://developer.apple.com/documentation/sirikit/media)
- Apple’s media sample implements audio playback through SiriKit Media Intents and requires SiriKit configuration plus an Intents extension. — [Managing Audio with SiriKit](https://developer.apple.com/documentation/sirikit/managing-audio-with-sirikit)
- Apple recommends App Intents when an app does not overlap an existing SiriKit domain. Schema-based natural-language support applies when the app’s action fits a defined schema. — [Bring your app to Siri, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10133/)
- Current schema domains include audio and photo-library actions, but no live TV tuning domain. Photo/video schemas describe photo-library operations; they do not imply general IPTV support. — [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- The `.audio` domain represents audio search and playback, using Media Intents and `IntentValueQuery`. — [Audio app schema domain](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)
- Current `playAudio` schema availability is iOS27+, and its union covers songs, live radio, podcasts, audiobooks and similar audio items. It provides no live TV channel item. — [playAudio](https://developer.apple.com/documentation/appintents/appschema/audiointent/playaudio)

### Inferences
- The smallest compatible fix stays with existing iOS17 App Intents. Do not adopt an unrelated photo/video schema or pretend a TV stream is radio.
- Document `Play Sky Mix in Accessible IPTV`, `Tune to Sky Mix in Accessible IPTV`, and `Watch Sky Mix in Accessible IPTV` for published channel entities.
- Document a parameter-free phrase such as `Watch TV in Accessible IPTV`, then answer Siri’s channel question for the complete catalog.
- For exact `Play Sky Mix` without the app name, create a personal Shortcut using the existing Tune channel action with Sky Mix selected, then name it `Play Sky Mix`.

### Gaps
- No public API found that guarantees intercepting arbitrary bare channel playback requests without app selection or user setup.
- Existing onscreen `userActivity.appEntityIdentifier` is contextual metadata, not evidence of full catalog recognition or a live TV assistant schema.

Inspected substantive content from 18 distinct linked Apple pages; alternate URLs for the same document were counted once. No product files changed.
