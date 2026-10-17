import Foundation

/// One provider reader across playback, CarPlay, casting, recordings and downloads.
@MainActor
public final class MediaConnection {
	public static let shared = MediaConnection()
	private var owner: UUID?
	private var teardown: Task<Void, Never>?

	public init() {}

	/// Replacements wait for teardown; an additional active reader is refused.
	public func acquire(_ id: UUID) async -> Bool {
		while let pending = teardown { await pending.value }
		guard !Task.isCancelled, owner == nil || owner == id else { return false }
		owner = id
		return true
	}

	/// Keep the slot until the transport has closed, including asynchronous VLC stops.
	public func release(_ id: UUID, after stop: @escaping @MainActor () async -> Void = {}) {
		guard owner == id, teardown == nil else { return }
		teardown = Task { @MainActor in
			await stop()
			owner = nil
			teardown = nil
		}
	}
}
