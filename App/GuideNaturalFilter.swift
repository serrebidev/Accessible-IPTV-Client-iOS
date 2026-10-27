import Foundation
import IPTVCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A plain-words guide request turned into structured filters, by the
/// on-device Foundation Models framework only. The README promises no
/// provider data goes to an AI service: no Private Cloud Compute, no
/// third-party model. The model never invents listings — its output is a
/// filter applied to the local guide, and the whole feature hides when the
/// on-device model is unavailable.
struct GuideFilterSpec: Equatable {
	var keywords = ""
	var category = ""
	var channelText = ""
	/// Local hours of day, 0-23; nil means no time bound on that side.
	var earliestHour: Int?
	var latestHour: Int?

	var isEmpty: Bool {
		keywords.isEmpty && category.isEmpty && channelText.isEmpty && earliestHour == nil && latestHour == nil
	}

	/// The text an ordinary guide search should run to gather candidates.
	var searchTerm: String {
		if !keywords.isEmpty { return keywords }
		if !channelText.isEmpty { return channelText }
		return category
	}
}

enum GuideNaturalFilter {
	static var isAvailable: Bool {
		#if canImport(FoundationModels)
		if #available(iOS 26.0, *) {
			return SystemLanguageModel.default.availability == .available
		}
		#endif
		return false
	}

	/// Pure application of a parsed spec, shared by the view and the tests.
	/// Hours are read in the device's local time zone.
	static func apply(_ spec: GuideFilterSpec, to pairs: [(Programme, Channel)], calendar: Calendar = .current) -> [(Programme, Channel)] {
		pairs.filter { p, ch in
			if !spec.keywords.isEmpty,
				!p.title.localizedCaseInsensitiveContains(spec.keywords),
				!p.description.localizedCaseInsensitiveContains(spec.keywords) { return false }
			if !spec.category.isEmpty, !ch.group.localizedCaseInsensitiveContains(spec.category) { return false }
			if !spec.channelText.isEmpty, !ch.name.localizedCaseInsensitiveContains(spec.channelText) { return false }
			let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: Double(p.start) / 1000))
			if let earliest = spec.earliestHour, hour < earliest { return false }
			if let latest = spec.latestHour, hour > latest { return false }
			return true
		}
	}

	static func parse(_ text: String) async -> GuideFilterSpec? {
		#if canImport(FoundationModels)
		if #available(iOS 26.0, *) {
			return await OnDeviceParser.parse(text)
		}
		#endif
		return nil
	}
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum OnDeviceParser {
	@Generable
	struct Parsed {
		@Guide(description: "Words a title or description search should match, in the language of the guide; empty when the request names none")
		var keywords: String
		@Guide(description: "A programme category such as sports, news, movies or children; empty when none is named")
		var category: String
		@Guide(description: "A channel name the request names; empty when none")
		var channel: String
		@Guide(description: "Earliest hour of day, 0 to 23, programmes may start; -1 when the request sets no earliest time")
		var earliestHour: Int
		@Guide(description: "Latest hour of day, 0 to 23, programmes may start; -1 when the request sets no latest time")
		var latestHour: Int
	}

	static func parse(_ text: String) async -> GuideFilterSpec? {
		let session = LanguageModelSession(instructions: """
			Turn a TV guide request into filters. "Tonight" means from 18:00. \
			"After 8" in the evening means 20:00. Set a field only when the request names it.
			""")
		guard let response = try? await session.respond(to: text, generating: Parsed.self) else { return nil }
		let parsed = response.content
		var spec = GuideFilterSpec()
		spec.keywords = parsed.keywords.trimmingCharacters(in: .whitespaces)
		spec.category = parsed.category.trimmingCharacters(in: .whitespaces)
		spec.channelText = parsed.channel.trimmingCharacters(in: .whitespaces)
		if (0...23).contains(parsed.earliestHour) { spec.earliestHour = parsed.earliestHour }
		if (0...23).contains(parsed.latestHour) { spec.latestHour = parsed.latestHour }
		return spec.isEmpty ? nil : spec
	}
}
#endif
