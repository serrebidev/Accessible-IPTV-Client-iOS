import Foundation

/// Bounded channel discovery for system pickers, voice commands and Shortcuts.
public enum ChannelDiscovery {
	/// Unnamed playlist entries can use credential-bearing URLs as labels. Keep those local.
	public static func publicText(_ text: String) -> String { text.contains("://") ? "" : text }

	public static func matching(_ channels: [Channel], _ text: String) -> [Channel] {
		let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return [] }
		if let number = Int(query), number > 0 {
			let matches = channels.filter { Int($0.number) == number }
			if !matches.isEmpty { return matches }
			if let channel = Channel.byNumber(channels, query) { return [channel] }
		}
		return Lists.searchRanked(channels, query)
	}

	public static func suggestions(_ channels: [Channel], favorites: Set<String>, recent: [String]) -> [Channel] {
		let byKey = Dictionary(channels.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
		var seen = Set<String>()
		let ordered = channels.filter { favorites.contains($0.key) } + recent.compactMap { byKey[$0] } + channels
		var result: [Channel] = []
		for channel in ordered where seen.insert(channel.key).inserted {
			result.append(channel)
			if result.count == 20 { break }
		}
		return result
	}
}
