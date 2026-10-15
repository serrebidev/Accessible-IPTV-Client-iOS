import Foundation

/// SharePlay with one provider connection: the host's player is the only one that opens the
/// provider. Its stream is remuxed to MPEG-TS, cut into whole-packet chunks and handed to the
/// other participants through Apple's encrypted SharePlay journal. Guests never see the URL.
public enum Relay {
	/// MPEG-TS packet size. Chunks hold whole packets, so a guest can start at any chunk.
	public static let packet = 188
	/// Largest chunk sent at once. Apple's journal accepts up to 100 MB per attachment.
	public static let maxChunk = 8 * 1024 * 1024
	/// Chunks kept in the journal: late joiners start from these, older ones are removed.
	public static let window = 8
	/// Chunks a joining guest starts behind the newest one, to hold a small cushion.
	public static let lead = 2
	/// How often the host cuts a chunk: fewer, larger attachments, about four seconds behind the host.
	public static let chunkNanoseconds: UInt64 = 2_000_000_000

	/// Bytes of `available` that form whole packets, capped at one chunk.
	public static func cut(_ available: Int) -> Int { min(max(0, available), maxChunk) / packet * packet }

	/// Offset of the first packet in `bytes`: three sync bytes 188 apart. Nil until enough has arrived.
	public static func syncOffset(_ bytes: [UInt8]) -> Int? {
		guard bytes.count >= packet * 3 else { return nil }
		for i in 0..<packet where bytes[i] == 0x47 && bytes[i + packet] == 0x47 && bytes[i + 2 * packet] == 0x47 {
			return i
		}
		return nil
	}
}

/// One chunk in the journal. The hash binds the attachment to the host's announcement, since
/// journal attachments do not say who added them.
public struct RelayEntry: Codable, Equatable, Sendable {
	public let seq: Int
	public let id: UUID
	public let sha256: String
	public let size: Int

	public init(seq: Int, id: UUID, sha256: String, size: Int) {
		self.seq = seq; self.id = id; self.sha256 = sha256; self.size = size
	}
}

/// Sent by the host after every chunk and every pause or seek. The generation changes when the
/// stream restarts (seek, new programme), so guests drop what they buffered.
public struct RelayWindow: Codable, Equatable, Sendable {
	public let generation: UUID
	public let paused: Bool
	public let entries: [RelayEntry]

	public init(generation: UUID, paused: Bool, entries: [RelayEntry]) {
		self.generation = generation; self.paused = paused; self.entries = entries
	}

	/// Messages cross a trust boundary: bounded, ascending, sane sizes and hashes.
	public var isValid: Bool {
		guard entries.count <= Relay.window * 2 else { return false }
		for (i, e) in entries.enumerated() {
			guard e.size > 0, e.size <= Relay.maxChunk, e.size % Relay.packet == 0, e.seq >= 0,
				e.sha256.count == 64, e.sha256.allSatisfy(\.isHexDigit) else { return false }
			if i > 0 && e.seq <= entries[i - 1].seq { return false }
		}
		return true
	}
}

/// A guest asks the host to pause or play; the host acts and announces the result.
public struct RelayRequest: Codable, Equatable, Sendable {
	public enum Action: String, Codable, Sendable { case play, pause }
	public let action: Action

	public init(_ action: Action) { self.action = action }
}

/// Which chunk a guest fetches next. Pure, so the ordering rules are tested without SharePlay.
public struct RelayReceiver: Sendable {
	public private(set) var generation: UUID?
	public private(set) var next = 0

	public init() {}

	/// The next chunk to fetch from `window`. `reset` is true when the stream restarted and the
	/// guest must drop its buffer first. A guest that fell behind skips to the oldest chunk left:
	/// MPEG-TS resynchronises on the next packet.
	public mutating func next(in window: RelayWindow) -> (reset: Bool, entry: RelayEntry?) {
		guard window.isValid, let first = window.entries.first, let last = window.entries.last else {
			return (false, nil)
		}
		var reset = false
		if window.generation != generation {
			generation = window.generation
			next = max(first.seq, last.seq - Relay.lead + 1)
			reset = true
		}
		if next < first.seq { next = first.seq }
		return (reset, window.entries.first { $0.seq >= next })
	}

	/// Called once a chunk was appended, or given up on.
	public mutating func advance(past seq: Int) { next = max(next, seq + 1) }
}

/// The relayed stream in memory, read by local players through the loopback server and by the
/// host's uploader. Bounded: readers that fall behind jump forward to the oldest byte kept.
public final class RelayBuffer: @unchecked Sendable {
	private let lock = NSCondition()
	private var bytes: [UInt8] = []
	/// Absolute offset of bytes[0].
	private var base = 0
	private var closed = false
	public let capacity: Int

	public init(capacity: Int = 32 * 1024 * 1024) { self.capacity = capacity }

	/// Absolute offset one past the newest byte.
	public var end: Int { lock.lock(); defer { lock.unlock() }; return base + bytes.count }

	public func append(_ data: [UInt8]) {
		guard !data.isEmpty else { return }
		lock.lock()
		bytes.append(contentsOf: data)
		// Trim in batches of whole packets, so a reader that jumps forward lands on a packet.
		if bytes.count > capacity + capacity / 4 {
			let drop = (bytes.count - capacity) / Relay.packet * Relay.packet
			bytes.removeFirst(drop)
			base += drop
		}
		lock.broadcast()
		lock.unlock()
	}

	/// Drops everything: a seek or restart. Offsets keep counting, so stale readers jump forward.
	public func reset() {
		lock.lock()
		base += bytes.count
		bytes.removeAll(keepingCapacity: true)
		lock.broadcast()
		lock.unlock()
	}

	public func close() {
		lock.lock()
		closed = true
		lock.broadcast()
		lock.unlock()
	}

	/// Where a new local player starts: `back` bytes behind the newest, on a packet boundary.
	public func start(back: Int) -> Int {
		lock.lock(); defer { lock.unlock() }
		let behind = min(bytes.count, max(0, back)) / Relay.packet * Relay.packet
		return base + bytes.count - behind
	}

	/// Up to `max` bytes from `offset`, waiting up to `timeout` for them. An offset that was
	/// trimmed or reset away continues at the oldest byte kept. Nil once closed and drained.
	public func read(from offset: Int, max: Int, timeout: TimeInterval) -> (bytes: [UInt8], next: Int)? {
		lock.lock(); defer { lock.unlock() }
		let deadline = Date(timeIntervalSinceNow: timeout)
		var from = Swift.max(offset, base)
		while from >= base + bytes.count {
			if closed { return nil }
			if !lock.wait(until: deadline) { return ([], from) }
			from = Swift.max(offset, base)
		}
		let start = from - base
		let count = Swift.min(max, bytes.count - start)
		return (Array(bytes[start..<start + count]), from + count)
	}
}
