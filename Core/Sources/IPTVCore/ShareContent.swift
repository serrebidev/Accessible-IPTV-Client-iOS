import Foundation

/// Public metadata only; each participant resolves playback through their own library.
public struct ShareContent: Codable, Equatable {
	public let name: String
	public let group: String
	public let kind: String
	public let tvgId: String
	public let archiveStart: Int64?
	public let archiveStop: Int64?
	public let season: Int?
	public let episode: Int?

	public init?(channel: Channel, archiveStart: Int64? = nil, archiveStop: Int64? = nil) {
		guard URL(string: channel.url)?.isFileURL != true else { return nil }
		name = ChannelDiscovery.publicText(channel.name).trimmingCharacters(in: .whitespacesAndNewlines)
		group = ChannelDiscovery.publicText(channel.group).trimmingCharacters(in: .whitespacesAndNewlines)
		kind = channel.kind
		tvgId = ChannelDiscovery.publicText(channel.tvgId).trimmingCharacters(in: .whitespacesAndNewlines)
		self.archiveStart = archiveStart
		self.archiveStop = archiveStop
		season = kind == Channel.kindEpisode ? Int(channel.attrs["season"] ?? "") : nil
		episode = kind == Channel.kindEpisode ? Int(channel.attrs["episode_num"] ?? "") : nil
		guard isValid else { return nil }
	}

	/// Decoded activities cross a trust boundary; validate before presenting or resolving them.
	public var isValid: Bool {
		guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			ChannelDiscovery.publicText(name) == name,
			ChannelDiscovery.publicText(group) == group,
			ChannelDiscovery.publicText(tvgId) == tvgId else { return false }
		if archiveStart != nil || archiveStop != nil {
			// Bound provider calendar conversion to 1970–2100 and programmes to seven days.
			guard kind == Channel.kindLive, let start = archiveStart, let stop = archiveStop,
				start > 0, stop > start, stop <= 4_102_444_800_000, stop - start <= 604_800_000 else { return false }
		}
		if kind == Channel.kindEpisode {
			return !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (season ?? 0) > 0 && (episode ?? 0) > 0
		}
		return (kind == Channel.kindLive || kind == Channel.kindMovie) && season == nil && episode == nil
	}

	/// Length prefixes prevent ambiguous field boundaries without process-randomized hashing.
	public var identifier: String {
		let fields = [name, group, kind, tvgId,
			archiveStart.map { String($0) } ?? "", archiveStop.map { String($0) } ?? "",
			season.map { String($0) } ?? "", episode.map { String($0) } ?? ""]
		return fields.map { "\($0.utf8.count):\($0)" }.joined()
	}

	public func matches(in channels: [Channel]) -> [Channel] {
		guard isValid else { return [] }
		if kind == Channel.kindEpisode {
			return channels.filter {
				$0.kind == kind && Lists.lowerName($0.group) == Lists.lowerName(group)
					&& Int($0.attrs["season"] ?? "") == season && Int($0.attrs["episode_num"] ?? "") == episode
			}
		}
		var matches = channels.filter { $0.kind == kind && Lists.lowerName($0.name) == Lists.lowerName(name) }
		if !tvgId.isEmpty {
			let byId = matches.filter { $0.tvgId == tvgId }
			if !byId.isEmpty { matches = byId }
		}
		if !group.isEmpty {
			let byGroup = matches.filter { Lists.lowerName($0.group) == Lists.lowerName(group) }
			if !byGroup.isEmpty { matches = byGroup }
		}
		return matches
	}
}
