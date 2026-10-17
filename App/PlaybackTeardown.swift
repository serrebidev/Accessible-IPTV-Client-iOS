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
			// `state` is VLCKit's cached copy of the core state, updated asynchronously.
			// A stop that races a just-started play can poll `.stopped` before the core
			// has even processed that play; the state then bounces back to `.stopping`
			// while VLC works through the queued stop, so one terminal read does not
			// prove the stop landed. The terminal state must hold across a settle
			// window; any non-terminal read restarts it. `isPlaying` queries VLC
			// synchronously, even before its cached state catches up with Start.
			var settledSince: TimeInterval?
			while true {
				if !player.isPlaying, player.state == .stopped || player.state == .error {
					let since = settledSince ?? ProcessInfo.processInfo.systemUptime
					settledSince = since
					if ProcessInfo.processInfo.systemUptime - since >= 0.5 { break }
				} else {
					settledSince = nil
				}
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
