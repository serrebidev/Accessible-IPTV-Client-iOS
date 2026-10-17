import Foundation
import AVFoundation
import VLCKit

/// VLCKit 4 stops asynchronously. Never open another provider connection until teardown finishes.
/// VLCKit 4's `state` is not KVO-observable, so teardown completion is polled, not observed.
@MainActor
enum PlaybackTeardown {
	private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

	static func stop(_ player: AVPlayer) {
		guard let item = player.currentItem else { return }
		player.pause()
		item.asset.cancelLoading()
		player.replaceCurrentItem(with: nil)
		let id = ObjectIdentifier(player)
		// shortcut: AVPlayer exposes no transport-close callback; allow provider sessions to expire after cancellation.
		pending[id] = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 2_500_000_000)
			withExtendedLifetime(player) { _ = pending.removeValue(forKey: id) }
		}
	}

	static func finished() async {
		while let task = pending.values.first { await task.value }
	}

	static func play(_ player: VLCMediaPlayer) {
		guard pending[ObjectIdentifier(player)] == nil, player.media != nil else { return }
		player.play()
	}

	@discardableResult static func stop(_ player: VLCMediaPlayer) -> Task<Void, Never> {
		let id = ObjectIdentifier(player)
		if let task = pending[id] { return task }
		// This public setter synchronously drains VLCKit's queued play/pause commands.
		player.drawable = player.drawable
		player.stop()
		player.media = nil
		let task = Task { @MainActor in
			// Polling starts only after stop() is queued behind any pending play(), so a
			// `.stopped` left over from a previous natural end cannot finish this wait:
			// stop() has already acted on the new play command. `isPlaying` queries VLC
			// synchronously, even before its cached state catches up with Start.
			while player.isPlaying || (player.state != .stopped && player.state != .error) {
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
