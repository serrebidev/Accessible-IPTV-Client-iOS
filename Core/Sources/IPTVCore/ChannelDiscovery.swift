import Foundation

/// Bounded channel discovery for system pickers, voice commands and Shortcuts.
public enum ChannelDiscovery {
	/// Unnamed playlist entries can use credential-bearing URLs as labels. Keep those local.
	public static func publicText(_ text: String) -> String { text.contains("://") ? "" : text }

	/// Provider decoration is not normally spoken; retain numbers and +1 timeshift labels.
	public static func spokenName(_ text: String) -> String {
		publicText(text)
			.replacingOccurrences(of: #"^[A-Za-z]{2,3}\s*[:|]\s*"#, with: "", options: .regularExpression)
			.replacingOccurrences(of: #"\b(?i:hd|fhd|uhd|sd|4k|hevc|h265|1080p|720p|backup|raw)\b"#, with: "", options: .regularExpression)
			.replacingOccurrences(of: #"[\s|:\[\]()_]+"#, with: " ", options: .regularExpression)
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public static func matching(_ channels: [Channel], _ text: String) -> [Channel] {
		let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return [] }
		if let number = Int(query), number > 0 {
			let matches = channels.filter { Int($0.number) == number }
			if !matches.isEmpty { return matches }
			if let channel = Channel.byNumber(channels, query) { return [channel] }
		}
		let ranked = Lists.searchRanked(channels, query)
		let key = Xmltv.nameKey(query)
		guard !key.isEmpty else { return ranked }
		let lowerQuery = Lists.lowerName(query)
		let exact = ranked.filter { Lists.lowerName($0.name) == lowerQuery }
		let names = channels.map { Xmltv.nameKey(publicText($0.name)) }
		let aliases = Lists.ranked(channels, names, key)
		var seen = Set<String>()
		return (exact + aliases + ranked).filter { seen.insert($0.key).inserted }
	}

	public static func nameMatches(_ name: String, _ query: String, exact: Bool) -> Bool {
		let name = publicText(name), query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty, !query.isEmpty else { return false }
		if exact ? name.compare(query, options: .caseInsensitive) == .orderedSame : name.containsCI(query) { return true }
		let key = Xmltv.nameKey(query), candidate = Xmltv.nameKey(name)
		return !key.isEmpty && (exact ? candidate == key : candidate.contains(key))
	}

	/// Resolution for one spoken channel by a system picker: a number, or a name that is spoken
	/// exactly, wins outright. [matching] still answers everything else, but a channel with many
	/// look-alikes is never left to compete with its siblings for a place in a short list.
	public static func resolve(_ channels: [Channel], _ text: String, limit: Int = 20) -> [Channel] {
		let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty, limit > 0 else { return [] }
		if let number = Int(query), number > 0 {
			let byNumber = channels.filter { Int($0.number) == number }
			if !byNumber.isEmpty { return Array(byNumber.prefix(limit)) }
		}
		let spoken = Lists.lowerName(spokenName(query))
		if !spoken.isEmpty {
			let said = channels.filter { Lists.lowerName(spokenName($0.name)) == spoken }
			if !said.isEmpty { return Array(said.prefix(limit)) }
		}
		let plain = Lists.lowerName(publicText(query))
		let named = channels.filter { Lists.lowerName(publicText($0.name)) == plain }
		if !named.isEmpty { return Array(named.prefix(limit)) }
		return Array(matching(channels, query).prefix(limit))
	}

	public static func suggestions(_ channels: [Channel], favorites: Set<String>, recent: [String]) -> [Channel] {
		let byKey = Dictionary(channels.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
		var seen = Set<String>()
		let preferred = channels.filter { favorites.contains($0.key) } + recent.compactMap { byKey[$0] }
		// Siri builds its initial phrase vocabulary from these: never let favourites hide recent channels.
		let limit = max(20, Set(preferred.map(\.key)).count)
		let ordered = preferred + channels
		var result: [Channel] = []
		for channel in ordered where seen.insert(channel.key).inserted {
			result.append(channel)
			if result.count == limit { break }
		}
		return result
	}
}
