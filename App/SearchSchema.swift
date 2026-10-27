#if os(iOS) && canImport(MediaIntents)
import AppIntents
import IPTVCore

// The iOS 27 system search schema: Siri AI can hand a natural guide search
// ("find the football tonight") straight to the app's own guide search,
// without the "in Accessible IPTV" phrase the custom SearchGuideIntent
// needs. SearchGuideIntent stays for iOS 18-26 and for Shortcuts.
// `canImport(MediaIntents)` stands in for "this SDK has the iOS 27
// schemas", the same gate ChannelAudioSchema uses, so older SDKs build
// this file as nothing.

@available(iOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct GuideSearchSchemaIntent: ShowInAppSearchResultsIntent {
	static var supportedModes: IntentModes { .foreground }
	static var allowedExecutionTargets: IntentExecutionTargets { .main }
	static let searchScopes: [StringSearchScope] = [.general]

	@Parameter var criteria: StringSearchCriteria

	@MainActor func perform() async throws -> some IntentResult {
		AppModel.shared.openGuideSearch(criteria.term)
		return .result()
	}
}
#endif
