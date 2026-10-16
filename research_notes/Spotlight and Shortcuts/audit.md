# Spotlight and Shortcuts audit

Audited 2026-10-16 against the existing 0.3.4 channel actions. The reported failure is channel recognition, not playback after selection.

## Findings and decisions

- App Shortcut initial phrases use a small published vocabulary. The app previously provided no Spotlight catalogue. Index all loaded live channels in batches; retain bounded initial suggestions rather than enumerate the full catalogue as shortcut suggestions.
- Apple recommends associating `IndexedEntity` instances with Spotlight content and providing an `OpenIntent`. This can help Siri and Apple Intelligence locate app data; it does not guarantee arbitrary spoken phrases or introduce a live-TV assistant schema.
- `IndexedEntity` and `associateAppEntity` require iOS 18. Use ordinary Core Spotlight items on iOS 17 with `CSSearchableItemActionType` continuation. Preserve the same opaque SHA-256 IDs for saved shortcuts and search results.
- A named index separates channel search from other app content. Index only public channel names, clean aliases, groups and numbers. Exclude URLs, logins, raw keys and remote logo requests.
- Persist the union of old/new opaque identifiers before updates. This lets a subsequent run delete items left by interrupted indexing. Serialize cancelled updates, batch insertions/deletions, skip unchanged completed catalogues and handle the index delegate’s rebuild requests.
- Existing `entities(for:)` filtered playlist order, losing requested input order. Resolve in identifier order and retain the first occurrence of duplicate provider IDs.
- Add `EntityPropertyQuery` for native Shortcuts filtering/sorting/limits. Retain `EntityStringQuery` for typed/spoken names and the full catalogue. Do not replace it with `EnumerableEntityQuery` for very large playlists.
- Add parameter summaries, a channel result from Tune channel, and a `Transferable` name representation. Keep existing action identifiers and parameter names so saved shortcuts remain compatible.
- Discovery refresh belongs at completion of the shared live loader. Coalesce Siri loads and remember which source configuration was loaded to avoid a refresh/load loop while source changes await the browse screen.

## Primary sources inspected

- [Spotlight integration](https://developer.apple.com/documentation/appintents/spotlight)
- [Making app entities available in Spotlight](https://developer.apple.com/documentation/appintents/making-app-entities-available-in-spotlight)
- [IndexedEntity](https://developer.apple.com/documentation/appintents/indexedentity) and [attributeSet](https://developer.apple.com/documentation/appintents/indexedentity/attributeset)
- [Associating an entity with search attributes](https://developer.apple.com/documentation/corespotlight/cssearchableitemattributeset/associateappentity(_:priority:))
- [Core Spotlight searchable items](https://developer.apple.com/documentation/corespotlight/cssearchableitem)
- [Opening a searchable item](https://developer.apple.com/documentation/corespotlight/cssearchableitemactivityidentifier)
- [Search index delegate](https://developer.apple.com/documentation/corespotlight/cssearchableindexdelegate)
- [EntityPropertyQuery](https://developer.apple.com/documentation/appintents/entitypropertyquery)
- [OpenIntent](https://developer.apple.com/documentation/appintents/openintent)
- [Contextual cues for Siri and Apple Intelligence](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [Transferable support, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10134/)
- [Booky’s property query implementation](https://github.com/mralexhay/Booky/blob/main/Shortcuts/ShortcutsBookEntity.swift)

API declarations and deployment versions were checked in Apple’s DocC JSON when necessary. Physical-device Siri recognition, indexing latency, search ranking and locked-device behaviour cannot be established from a Windows host or simulator tests.
