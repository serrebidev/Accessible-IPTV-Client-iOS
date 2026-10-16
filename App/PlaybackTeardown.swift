import Foundation
import VLCKit

/// Default VLCKit events run on its callback thread, including KVO.
private final class PlaybackStopState: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	var observation: NSKeyValueObservation?
	var terminal: Bool {
		get { lock.lock(); defer { lock.unlock() }; return value }
		set { lock.lock(); defer { lock.unlock() }; value = newValue }
	}
}

/// VLCKit 4 stops asynchronously. Never open another provider connection until teardown finishes.
@MainActor
enum PlaybackTeardown {
	private static var entries: [ObjectIdentifier: PlaybackStopState] = [:]
	private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

	static func play(_ player: VLCMediaPlayer) {
		let id = ObjectIdentifier(player)
		guard pending[id] == nil, player.media != nil else { return }
		let entry: PlaybackStopState
		if let existing = entries[id] { entry = existing }
		else {
			entry = PlaybackStopState()
			entry.observation = player.observe(\.state, options: [.new]) { [weak entry] _, change in
				entry?.terminal = change.newValue == .stopped
			}
			entries[id] = entry
		}
		entry.terminal = false
		player.play()
	}

	@discardableResult static func stop(_ player: VLCMediaPlayer) -> Task<Void, Never> {
		let id = ObjectIdentifier(player)
		if let task = pending[id] { return task }
		// This public setter synchronously drains VLCKit's queued play/pause commands.
		player.drawable = player.drawable
		let entry = entries[id]
		// isPlaying queries VLC synchronously, even before its cached state catches up with Start.
		if player.isPlaying || player.state != .stopped { entry?.terminal = false }
		let wait = entry.map { !$0.terminal } ?? (player.state != .stopped)
		player.stop()
		player.media = nil
		let task = Task { @MainActor in
			while wait && (entry.map { !$0.terminal } ?? (player.state != .stopped)) {
				try? await Task.sleep(nanoseconds: 100_000_000)
			}
			entries.removeValue(forKey: id)
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
