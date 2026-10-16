#if os(iOS)
import AppIntents
import CoreSpotlight
import CryptoKit
import IPTVCore
import UniformTypeIdentifiers

/// A named, on-device index. Stream URLs and provider identifiers never enter search metadata.
@MainActor
final class ChannelSpotlight: NSObject {
	nonisolated static let domain = "dev.serrebi.accessibleiptv.channels"
	static let shared = ChannelSpotlight(index: CSSearchableIndex(name: domain),
		stateFile: AppModel.dataDir.appendingPathComponent("channel-search.json"), report: { AppModel.shared.setStatus($0) })

	struct State: Codable {
		var fingerprint: String?
		var identifiers: Set<String>
	}
	struct Snapshot {
		let channels: [Channel]
		let state: State
	}
	private let index: CSSearchableIndex
	private let stateFile: URL
	private let report: @MainActor (String) -> Void
	private var state: State?
	private var work: Task<Void, Never>?

	init(index: CSSearchableIndex, stateFile: URL, report: @escaping @MainActor (String) -> Void) {
		self.index = index; self.stateFile = stateFile; self.report = report
		state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
		super.init()
		index.indexDelegate = self
	}

	nonisolated static func attributes(_ entity: TVChannelEntity) -> CSSearchableItemAttributeSet {
		let attributes = CSSearchableItemAttributeSet(contentType: .movie)
		attributes.title = entity.name
		attributes.displayName = entity.name
		attributes.alternateNames = entity.spokenName.isEmpty ? [] : [entity.spokenName]
		attributes.keywords = [entity.spokenName, entity.category, entity.number].filter { !$0.isEmpty }
		attributes.contentDescription = Format.sentences([entity.category, entity.number])
		return attributes
	}

	nonisolated static func item(_ channel: Channel) -> CSSearchableItem {
		let entity = TVChannelEntity(channel)
		let attributes = attributes(entity)
		if #available(iOS 18, *) { attributes.associateAppEntity(entity) }
		let item = CSSearchableItem(uniqueIdentifier: entity.id, domainIdentifier: domain, attributeSet: attributes)
		item.expirationDate = .distantFuture
		return item
	}

	nonisolated static func snapshot(_ channels: [Channel]) -> Snapshot {
		var seen = Set<String>(), identifiers = Set<String>()
		let channels = channels.filter { $0.isLive && !ChannelDiscovery.publicText($0.name).isEmpty && seen.insert($0.key).inserted }
		var hash = SHA256()
		hash.update(data: Data("channel-search-v1".utf8))
		for channel in channels {
			let id = TVChannelEntity.identifier(channel)
			identifiers.insert(id)
			for field in [id, ChannelDiscovery.publicText(channel.name), ChannelDiscovery.publicText(channel.group), ChannelDiscovery.publicText(channel.number)] {
				let bytes = Data(field.utf8)
				hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
			}
		}
		let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
		return Snapshot(channels: channels, state: State(fingerprint: fingerprint, identifiers: identifiers))
	}

	@discardableResult
	func update(_ channels: [Channel], force: Bool = false) -> Task<Void, Never> {
		let previous = work
		previous?.cancel()
		let task = Task {
			await previous?.value
			do {
				try Task.checkCancellation()
				let snapshot = await Task.detached { Self.snapshot(channels) }.value
				try Task.checkCancellation()
				if !force, state?.fingerprint == snapshot.state.fingerprint { return }
				report(L("search_index_updating"))
				if state == nil { try await index.deleteAllSearchableItems() }
				let old = state?.identifiers ?? []
				// Persist the union first: a restart can remove items from an interrupted indexing run.
				let pending = State(fingerprint: nil, identifiers: old.union(snapshot.state.identifiers))
				try JSONEncoder().encode(pending).write(to: stateFile, options: .atomic)
				state = pending
				let removed = old.subtracting(snapshot.state.identifiers)
				if snapshot.channels.isEmpty {
					try await index.deleteAllSearchableItems()
				} else {
					let identifiers = Array(removed)
					for offset in stride(from: 0, to: identifiers.count, by: 500) {
						try Task.checkCancellation()
						try await index.deleteSearchableItems(withIdentifiers: Array(identifiers[offset..<min(offset + 500, identifiers.count)]))
					}
				}
				for offset in stride(from: 0, to: snapshot.channels.count, by: 500) {
					try Task.checkCancellation()
					let batch = Array(snapshot.channels[offset..<min(offset + 500, snapshot.channels.count)])
					let items = await Task.detached { batch.map(Self.item) }.value
					try Task.checkCancellation()
					try await index.indexSearchableItems(items)
				}
				try Task.checkCancellation()
				try JSONEncoder().encode(snapshot.state).write(to: stateFile, options: .atomic)
				state = snapshot.state
				report(L("search_index_ready", snapshot.channels.count))
			} catch is CancellationError {
				// The next queued catalogue update completes the interrupted work.
			} catch {
				report(L("search_index_failed"))
			}
		}
		work = task
		return task
	}

	private nonisolated func reindex(_ acknowledge: @escaping () -> Void) {
		Task { @MainActor in
			if AppModel.shared.prefs.sources.isEmpty {
				await update([], force: true).value
			} else {
				do { await update(try await SiriLibrary.live(), force: true).value }
				catch { report(L("search_index_failed")) }
			}
			acknowledge()
		}
	}
}

extension ChannelSpotlight: CSSearchableIndexDelegate {
	nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex,
		reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
		reindex(acknowledgementHandler)
	}

	nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String],
		acknowledgementHandler: @escaping () -> Void) {
		reindex(acknowledgementHandler)
	}
}

extension AppModel {
	func openSpotlight(_ activity: NSUserActivity) {
		guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
		Task {
			do {
				let channels = try await SiriLibrary.live()
				guard let entity = await Task.detached(operation: { TVChannelQuery.resolve([id], in: channels).first }).value else {
					throw SiriLibrary.ActionError.message(L("channel_unavailable"))
				}
				_ = try await SiriLibrary.tune(entity)
			} catch { setStatus(error.localizedDescription) }
		}
	}
}
#endif
