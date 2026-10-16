import CoreSpotlight
import IPTVCore
import XCTest
@testable import AccessibleIPTV

final class ChannelSpotlightTests: XCTestCase {
	private func channel(_ id: String, _ name: String = "UK: Sky | Mix HD") -> Channel {
		Channel(sourceId: "s", itemId: id, name: name, group: "Entertainment", url: "https://provider/user/password/\(id)", attrs: [Channel.chno: id])
	}

	@MainActor
	func testIndexRemovesOldChannelsAndRecoversAfterInterruptedWrite() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = TestSearchIndex(testName: UUID().uuidString)
		let file = dir.appendingPathComponent("state.json")
		var reports: [String] = []
		var search = ChannelSpotlight(index: store, stateFile: file, report: { reports.append($0) })
		let a = channel("1"), b = channel("2", "BBC One"), c = channel("3", "ITV")
		await search.update([a, a, b]).value
		XCTAssertEqual(Set(store.items.keys), [TVChannelEntity.identifier(a), TVChannelEntity.identifier(b)])
		let calls = store.writes
		await search.update([a, a, b]).value
		XCTAssertEqual(store.writes, calls, "Unchanged catalogues must not be indexed again")
		store.failNextWrite = true
		await search.update([a, c]).value
		XCTAssertEqual(reports.last, L("search_index_failed"))
		search = ChannelSpotlight(index: store, stateFile: file, report: { reports.append($0) })
		await search.update([c]).value
		XCTAssertEqual(Set(store.items.keys), [TVChannelEntity.identifier(c)])
		await search.update([]).value
		XCTAssertTrue(store.items.isEmpty, "Removing all sources must remove Spotlight results")
		let persisted = try String(contentsOf: file, encoding: .utf8)
		XCTAssertFalse(persisted.contains("password"))
		XCTAssertFalse(persisted.contains("provider"))
	}

	@MainActor
	func testLargeCataloguesAreBatchedAndCanBeReindexed() async throws {
		let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: dir) }
		let store = TestSearchIndex(testName: UUID().uuidString)
		let search = ChannelSpotlight(index: store, stateFile: dir.appendingPathComponent("state.json"), report: { _ in })
		let channels = (1...501).map { channel(String($0)) }
		await search.update(channels).value
		XCTAssertEqual(store.items.count, 501)
		XCTAssertEqual(store.largestBatch, 500)
		let writes = store.writes
		await search.update(channels, force: true).value
		XCTAssertEqual(store.writes, writes + 2)
	}

	func testIndexedMetadataContainsAliasesButNoProviderCredentials() {
		let item = ChannelSpotlight.item(channel("42"))
		XCTAssertEqual(item.attributeSet.title, "UK: Sky | Mix HD")
		XCTAssertTrue(item.attributeSet.keywords?.contains("Sky Mix") == true)
		XCTAssertTrue(item.attributeSet.keywords?.contains("42") == true)
		XCTAssertNil(item.attributeSet.contentURL)
		XCTAssertEqual(item.uniqueIdentifier.count, 64)
		XCTAssertFalse(item.uniqueIdentifier.contains("password"))
		let bad = channel("4", "https://user:password@provider/live")
		XCTAssertTrue(ChannelSpotlight.snapshot([bad]).channels.isEmpty)
	}
}

private final class TestSearchIndex: CSSearchableIndex, @unchecked Sendable {
	var items: [String: CSSearchableItem] = [:]
	var writes = 0
	var largestBatch = 0
	var failNextWrite = false
	private let lock = NSLock()
	init(testName: String) { super.init(name: "test-\(testName)") }

	override func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)? = nil) {
		let failed = lock.withLock {
			writes += 1
			largestBatch = max(largestBatch, items.count)
			if failNextWrite { failNextWrite = false; return true }
			for item in items { self.items[item.uniqueIdentifier] = item }
			return false
		}
		completionHandler?(failed ? NSError(domain: "test", code: 1) : nil)
	}

	override func deleteSearchableItems(withIdentifiers identifiers: [String], completionHandler: (@Sendable (Error?) -> Void)? = nil) {
		lock.withLock { for id in identifiers { items.removeValue(forKey: id) } }
		completionHandler?(nil)
	}

	override func deleteAllSearchableItems(completionHandler: (@Sendable (Error?) -> Void)? = nil) {
		lock.withLock { items.removeAll() }
		completionHandler?(nil)
	}
}
