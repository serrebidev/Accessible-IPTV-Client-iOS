#if os(iOS)
import AppIntents
import CoreSpotlight
import CryptoKit
import IPTVCore
import UniformTypeIdentifiers

/// Donates upcoming programmes to Spotlight and Siri's semantic index, the
/// same way ChannelSpotlight donates channels. The window is the next 24
/// hours; every item expires when its programme ends, and a guide refresh
/// re-runs the update so stale donations are removed. Stream URLs and
/// provider identifiers never enter search metadata.
@MainActor
final class ProgrammeSpotlight: NSObject {
	nonisolated static let domain = "dev.serrebi.accessibleiptv.programmes"
	static let shared = ProgrammeSpotlight(index: CSSearchableIndex(name: domain),
		stateFile: AppModel.dataDir.appendingPathComponent("programme-search.json"), report: { AppModel.shared.setStatus($0) })

	struct State: Codable {
		var fingerprint: String?
		var identifiers: Set<String>
	}
	struct Snapshot {
		let pairs: [(Programme, Channel)]
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

	nonisolated static func attributes(_ entity: ProgrammeEntity) -> CSSearchableItemAttributeSet {
		let attributes = CSSearchableItemAttributeSet(contentType: .movie)
		attributes.title = entity.title
		attributes.displayName = entity.title
		attributes.alternateNames = entity.channelName.isEmpty ? [] : [entity.channelName]
		attributes.keywords = [entity.title, entity.channelName, entity.category].filter { !$0.isEmpty }
		attributes.contentDescription = Format.sentences([entity.channelName, Format.dateTime(entity.startMs), entity.details])
		return attributes
	}

	nonisolated static func item(_ pair: (Programme, Channel)) -> CSSearchableItem {
		let entity = ProgrammeEntity(pair.0, pair.1)
		let attributes = attributes(entity)
		if #available(iOS 18, *) { attributes.associateAppEntity(entity) }
		let item = CSSearchableItem(uniqueIdentifier: entity.id, domainIdentifier: domain, attributeSet: attributes)
		item.expirationDate = Date(timeIntervalSince1970: Double(pair.0.stop) / 1000)
		return item
	}

	/// Programmes on now plus everything starting in the next 24 hours,
	/// earliest first, capped so a huge guide cannot flood the index.
	nonisolated static func pool(_ channels: [Channel], _ epg: Epg, now: Int64 = nowMs()) -> [(Programme, Channel)] {
		var pairs: [(Programme, Channel)] = []
		for ch in channels where epg.guideId(ch) != nil {
			pairs += epg.schedule(ch, from: now - 3_600_000, to: now + 86_400_000).map { ($0, ch) }
		}
		pairs.sort { $0.0.start < $1.0.start }
		return Array(pairs.prefix(20_000))
	}

	nonisolated static func snapshot(_ pairs: [(Programme, Channel)]) -> Snapshot {
		var seen = Set<String>(), identifiers = Set<String>()
		let pairs = pairs.filter { seen.insert(ProgrammeEntity.identifier($0.0)).inserted }
		var hash = SHA256()
		hash.update(data: Data("programme-search-v1".utf8))
		for (p, _) in pairs {
			identifiers.insert(ProgrammeEntity.identifier(p))
			for field in [ProgrammeEntity.identifier(p), p.title, p.channelName] {
				let bytes = Data(field.utf8)
				hash.update(data: Data("\(bytes.count):".utf8)); hash.update(data: bytes)
			}
		}
		let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
		return Snapshot(pairs: pairs, state: State(fingerprint: fingerprint, identifiers: identifiers))
	}

	@discardableResult
	func update(_ channels: [Channel], _ epg: Epg, force: Bool = false) -> Task<Void, Never> {
		let previous = work
		previous?.cancel()
		let task = Task {
			await previous?.value
			do {
				try Task.checkCancellation()
				let snapshot = await Task.detached { Self.snapshot(Self.pool(channels, epg)) }.value
				try Task.checkCancellation()
				if !force, state?.fingerprint == snapshot.state.fingerprint { return }
				if state == nil { try await index.deleteAllSearchableItems() }
				let old = state?.identifiers ?? []
				let pending = State(fingerprint: nil, identifiers: old.union(snapshot.state.identifiers))
				try JSONEncoder().encode(pending).write(to: stateFile, options: .atomic)
				state = pending
				let removed = old.subtracting(snapshot.state.identifiers)
				if snapshot.pairs.isEmpty {
					try await index.deleteAllSearchableItems()
				} else {
					let identifiers = Array(removed)
					for offset in stride(from: 0, to: identifiers.count, by: 500) {
						try Task.checkCancellation()
						try await index.deleteSearchableItems(withIdentifiers: Array(identifiers[offset..<min(offset + 500, identifiers.count)]))
					}
				}
				for offset in stride(from: 0, to: snapshot.pairs.count, by: 500) {
					try Task.checkCancellation()
					let batch = Array(snapshot.pairs[offset..<min(offset + 500, snapshot.pairs.count)])
					let items = await Task.detached { batch.map(Self.item) }.value
					try Task.checkCancellation()
					try await index.indexSearchableItems(items)
				}
				try Task.checkCancellation()
				try JSONEncoder().encode(snapshot.state).write(to: stateFile, options: .atomic)
				state = snapshot.state
			} catch is CancellationError {
				// The next queued guide update completes the interrupted work.
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
				await update([], AppModel.shared.library.epg, force: true).value
			} else {
				do {
					let channels = try await SiriLibrary.live()
					await update(channels, AppModel.shared.library.epg, force: true).value
				} catch { report(L("search_index_failed")) }
			}
			acknowledge()
		}
	}
}

extension ProgrammeSpotlight: CSSearchableIndexDelegate {
	nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex,
		reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
		reindex(acknowledgementHandler)
	}

	nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String],
		acknowledgementHandler: @escaping () -> Void) {
		reindex(acknowledgementHandler)
	}
}
#endif
