import Foundation
import VLCKit

/// VLCKit 4 stops asynchronously. Never open another provider connection until teardown finishes.
@MainActor
enum PlaybackTeardown {
	private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

	@discardableResult static func stop(_ player: VLCMediaPlayer) -> Task<Void, Never> {
		let id = ObjectIdentifier(player)
		if let task = pending[id] { return task }
		guard player.state != .stopped else { return Task {} }
		player.stop()
		let task = Task { @MainActor in
			while player.state != .stopped {
				try? await Task.sleep(nanoseconds: 100_000_000)
			}
			pending.removeValue(forKey: id)
		}
		pending[id] = task
		return task
	}

	static func ready() async -> Bool {
		let deadline = ProcessInfo.processInfo.systemUptime + 15
		while !pending.isEmpty {
			guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return false }
			do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
		}
		return !Task.isCancelled
	}
}
