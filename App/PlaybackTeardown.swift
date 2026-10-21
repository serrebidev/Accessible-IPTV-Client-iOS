import Foundation
import AVFoundation
import SwiftVLC

extension VLCInstance {
	/// One libVLC engine for every player. The app owns the audio session (background audio,
	/// CarPlay, AirPlay routing), so libVLC never touches it.
	static let app: VLCInstance = {
		do { return try VLCInstance(appleAudioSessionPolicy: .applicationManaged) }
		catch { fatalError("libVLC failed to start: \(error)") }
	}()

	/// libVLC's first start loads every plugin; doing it at launch keeps it off the first channel.
	static func warmUp() { Task.detached(priority: .userInitiated) { _ = VLCInstance.app } }
}

/// libVLC stops asynchronously. Never open another provider connection until teardown finishes.
@MainActor
enum PlaybackTeardown {
	private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
	/// Stopped players keep their last media; a bare play must not reopen it.
	private static var stopped = Set<ObjectIdentifier>()

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

	/// Opens new media, on this device or on a cast receiver; a renderer applies only before play.
	static func play(_ player: Player, _ media: Media, renderer: RendererItem? = nil) {
		let id = ObjectIdentifier(player)
		guard pending[id] == nil else { return }
		stopped.remove(id)
		player.load(media)
		try? player.setRenderer(renderer)
		try? player.play()
	}

	/// Resumes the loaded media.
	static func play(_ player: Player) {
		let id = ObjectIdentifier(player)
		guard pending[id] == nil, !stopped.contains(id), player.currentMedia != nil else { return }
		try? player.play()
	}

	@discardableResult static func stop(_ player: Player) -> Task<Void, Never> {
		let id = ObjectIdentifier(player)
		if let task = pending[id] { return task }
		stopped.insert(id)
		let task = Task { @MainActor in
			// Returns once libVLC released the input and its outputs (bounded at 10 s).
			await player.stopAndWait()
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
