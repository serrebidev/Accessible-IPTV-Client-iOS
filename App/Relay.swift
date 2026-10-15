import CryptoKit
import Foundation
import GroupActivities
import Network
import VLCKit
import IPTVCore

/// Serves a RelayBuffer to this device's VLC over loopback HTTP. The random path keeps other
/// apps on the device from reading it; the listener accepts loopback connections only.
final class RelayServer: @unchecked Sendable {
	let buffer: RelayBuffer
	private let path = "/\(UUID().uuidString).ts"
	private let queue = DispatchQueue(label: "dev.serrebi.accessibleiptv.relay.server")
	private var listener: NWListener?

	init(buffer: RelayBuffer) { self.buffer = buffer }

	/// Starts listening and returns the URL VLC plays.
	func start() async throws -> String {
		let params = NWParameters.tcp
		params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
		params.acceptLocalOnly = true
		let listener = try NWListener(using: params)
		self.listener = listener
		listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
		return try await withCheckedThrowingContinuation { continuation in
			var resumed = false
			listener.stateUpdateHandler = { [path, weak listener] state in
				guard !resumed else { return }
				switch state {
				case .ready:
					resumed = true
					continuation.resume(returning: "http://127.0.0.1:\(listener?.port?.rawValue ?? 0)\(path)")
				case .failed(let error):
					resumed = true
					continuation.resume(throwing: error)
				case .cancelled:
					resumed = true
					continuation.resume(throwing: CancellationError())
				default:
					break
				}
			}
			listener.start(queue: queue)
		}
	}

	func stop() {
		listener?.cancel()
		listener = nil
		buffer.close()
	}

	private func serve(_ connection: NWConnection) {
		connection.start(queue: queue)
		connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
			guard let self, let data, let head = String(data: data, encoding: .utf8),
				head.hasPrefix("GET \(self.path) ") else {
				connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
					completion: .contentProcessed { _ in connection.cancel() })
				return
			}
			// No Content-Length or Accept-Ranges: VLC treats the stream as live and never seeks it.
			connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8),
				completion: .idempotent)
			let buffer = self.buffer
			// A new player starts at the newest byte: the next keyframe, at the live edge.
			Thread.detachNewThread { Self.pump(connection, buffer: buffer, from: buffer.start(back: 0)) }
		}
	}

	/// One thread per player (one or two per device): waits for bytes, sends them, waits for the send.
	private static func pump(_ connection: NWConnection, buffer: RelayBuffer, from start: Int) {
		var offset = start
		let sent = DispatchSemaphore(value: 0)
		var failed = false
		while !failed {
			switch connection.state {
			case .cancelled, .failed: failed = true; continue
			default: break
			}
			guard let read = buffer.read(from: offset, max: Relay.packet * 348, timeout: 1) else { break }
			offset = read.next
			guard !read.bytes.isEmpty else { continue }
			connection.send(content: Data(read.bytes), completion: .contentProcessed { error in
				failed = error != nil
				sent.signal()
			})
			sent.wait()
		}
		connection.cancel()
	}
}

/// Reads the producer's loopback HTTP output into the buffer as whole MPEG-TS packets.
/// Reconnects when VLC's output is not listening yet or restarted.
final class RelayFeed: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let buffer: RelayBuffer
	private let request: URLRequest
	private let queue: OperationQueue = {
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		return queue
	}()
	private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
	private var pending: [UInt8] = []
	private var synced = false
	private var stopped = false

	init(buffer: RelayBuffer, url: URL, password: String) {
		var request = URLRequest(url: url)
		// A paused movie sends nothing for as long as it is paused.
		request.timeoutInterval = 3600
		request.setValue("Basic " + Data("relay:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
		self.request = request
		self.buffer = buffer
	}

	func start() { queue.addOperation { self.connect() } }

	func stop() {
		queue.addOperation {
			self.stopped = true
			self.session.invalidateAndCancel()
		}
	}

	private func connect() {
		guard !stopped else { return }
		pending = []
		synced = false
		session.dataTask(with: request).resume()
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		pending += data
		if !synced {
			guard let at = Relay.syncOffset(pending) else {
				if pending.count > 1 << 20 { pending.removeAll() }
				return
			}
			pending.removeFirst(at)
			synced = true
		}
		let whole = pending.count / Relay.packet * Relay.packet
		guard whole > 0 else { return }
		buffer.append(Array(pending[0..<whole]))
		pending.removeFirst(whole)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard !stopped else { return }
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
			self?.queue.addOperation { self?.connect() }
		}
	}
}

/// The host's single provider connection: its own VLC instance remuxes the provider stream to
/// MPEG-TS on a password-protected loopback port, without decoding it.
@MainActor
final class RelayProducer: NSObject, VLCMediaPlayerDelegate {
	let buffer = RelayBuffer()
	let live: Bool
	private let url: String
	private let player = VLCMediaPlayer(options: ["--http-host=127.0.0.1", "--vout=dummy", "--aout=dummy", "--ignore-config"])
	private let password = UUID().uuidString
	private var feed: RelayFeed?
	private let reconnect = Reconnect(clock: nowMs)
	private var retry: Task<Void, Never>?
	private var stopped = false
	private var played = false

	init(url: String, live: Bool) {
		self.url = url
		self.live = live
		super.init()
		player.delegate = self
	}

	func start() -> Bool {
		guard let port = Self.freePort(), let output = URL(string: "http://127.0.0.1:\(port)/relay.ts") else { return false }
		guard open(port: port) else { return false }
		let feed = RelayFeed(buffer: buffer, url: output, password: password)
		self.feed = feed
		feed.start()
		return true
	}

	private var port = 0

	private func open(port: Int) -> Bool {
		guard let media = PlayerController.providerMedia(url) else { return false }
		self.port = port
		media.addOption(":network-caching=1500")
		media.addOption(":sout=#std{access=http{user=relay,pwd=\(password),mime=video/mp2t},mux=ts,dst=127.0.0.1:\(port)/relay.ts}")
		media.addOption(":sout-all")
		player.media = media
		player.play()
		return true
	}

	/// Movies and catch-up pause at the source; a live channel keeps running and players rejoin at its edge.
	func pause() { if !live { player.pause() } }
	func resume() { if !live { player.play() } }

	func stop() {
		stopped = true
		retry?.cancel()
		player.stop()
		player.delegate = nil
		feed?.stop()
		buffer.close()
	}

	nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
		Task { @MainActor in self.stateChanged(newState) }
	}

	/// A dropped live channel reconnects, as the player does; the feed resynchronises on its own.
	/// Before the first picture any stream retries: one-connection providers refuse a new
	/// connection for a moment after the player's direct one closes.
	private func stateChanged(_ state: VLCMediaPlayerState) {
		if state == .playing { played = true }
		guard !stopped, live || !played, state == .error || state == .stopped, retry == nil, let delay = reconnect.next() else { return }
		retry = Task {
			try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
			retry = nil
			guard !Task.isCancelled, !stopped else { return }
			_ = open(port: port)
		}
	}

	/// A free loopback port for VLC's HTTP output. ponytail: the port is free when checked, not reserved.
	private static func freePort() -> Int? {
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		guard fd >= 0 else { return nil }
		defer { close(fd) }
		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr.s_addr = inet_addr("127.0.0.1")
		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let bound = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
		}
		return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
	}
}

/// SharePlay's data channels for the relay: one journal and one messenger per session.
@MainActor
final class RelayChannel {
	let journal: GroupSessionJournal
	let messenger: GroupSessionMessenger

	init(_ session: GroupSession<WatchTVActivity>) {
		journal = GroupSessionJournal(session: session)
		messenger = GroupSessionMessenger(session: session)
	}

	static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Host side: cuts the producer's stream into chunks, adds them to the journal and announces
/// them. Keeps the newest few in the journal for late joiners and removes the rest for everyone.
@MainActor
final class RelayHost {
	private let channel: RelayChannel
	private let buffer: RelayBuffer
	private let generation = UUID()
	private var seq = 0
	private var sent: [(entry: RelayEntry, attachment: GroupSessionJournal.Attachment)] = []
	private var paused = false
	private var tasks: [Task<Void, Never>] = []
	var onRequest: ((RelayRequest) -> Void)?

	init(channel: RelayChannel, buffer: RelayBuffer) {
		self.channel = channel
		self.buffer = buffer
	}

	func start() {
		tasks.append(Task { [weak self] in await self?.upload() })
		let messenger = channel.messenger
		tasks.append(Task { [weak self] in
			for await (request, _) in messenger.messages(of: RelayRequest.self) {
				guard !Task.isCancelled else { return }
				self?.onRequest?(request)
			}
		})
	}

	func setPaused(_ value: Bool) {
		paused = value
		Task { await announce() }
	}

	func stop() {
		tasks.forEach { $0.cancel() }
		tasks.removeAll()
		let journal = channel.journal
		let old = sent.map(\.attachment)
		sent.removeAll()
		Task { for attachment in old { try? await journal.remove(attachment: attachment) } }
	}

	private func upload() async {
		var offset = buffer.end
		let buffer = self.buffer
		while !Task.isCancelled {
			try? await Task.sleep(nanoseconds: Relay.chunkNanoseconds)
			let from = offset
			guard let read = await Task.detached(operation: { buffer.read(from: from, max: Relay.maxChunk, timeout: 0) }).value else { return }
			let size = Relay.cut(read.bytes.count)
			// Bytes left over (never in practice: the feed appends whole packets) go in the next chunk.
			offset = read.next - (read.bytes.count - size)
			if size > 0 { await send(Data(read.bytes[0..<size])) }
			await announce()
		}
	}

	private func send(_ data: Data) async {
		let entry = RelayEntry(seq: seq, id: UUID(), sha256: RelayChannel.sha256(data), size: data.count)
		seq += 1
		do {
			let attachment = try await channel.journal.add(data)
			sent.append((RelayEntry(seq: entry.seq, id: attachment.id, sha256: entry.sha256, size: entry.size), attachment))
		} catch {
			return
		}
		while sent.count > Relay.window {
			let old = sent.removeFirst().attachment
			try? await channel.journal.remove(attachment: old)
		}
	}

	/// Sent every chunk, so late joiners learn the window and the pause state within seconds.
	private func announce() async {
		try? await channel.messenger.send(RelayWindow(generation: generation, paused: paused, entries: sent.map(\.entry)))
	}
}

/// Guest side: follows the host's announcements, downloads each announced chunk once, checks
/// its hash and size, and feeds the local player. Never contacts the provider.
@MainActor
final class RelayGuest {
	let buffer = RelayBuffer()
	let host: UUID
	private let channel: RelayChannel
	private var receiver = RelayReceiver()
	private var latest: RelayWindow?
	private var attachments: [UUID: GroupSessionJournal.Attachment] = [:]
	private var fetching = false
	private var tasks: [Task<Void, Never>] = []
	private(set) var paused = false
	var onReset: (() -> Void)?
	var onPaused: ((Bool) -> Void)?

	init(channel: RelayChannel, host: UUID) {
		self.channel = channel
		self.host = host
	}

	func start() {
		let messenger = channel.messenger, journal = channel.journal, host = host
		tasks.append(Task { [weak self] in
			for await (window, context) in messenger.messages(of: RelayWindow.self) {
				guard !Task.isCancelled else { return }
				guard context.source.id == host, window.isValid else { continue }
				self?.received(window)
			}
		})
		tasks.append(Task { [weak self] in
			for await list in journal.attachments {
				guard !Task.isCancelled else { return }
				self?.attachments = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
				self?.pump()
			}
		})
	}

	func request(_ action: RelayRequest.Action) {
		let messenger = channel.messenger
		Task { try? await messenger.send(RelayRequest(action)) }
	}

	func stop() {
		tasks.forEach { $0.cancel() }
		tasks.removeAll()
		latest = nil
		buffer.close()
	}

	private func received(_ window: RelayWindow) {
		latest = window
		if window.paused != paused {
			paused = window.paused
			onPaused?(paused)
		}
		pump()
	}

	private func pump() {
		guard !fetching else { return }
		fetching = true
		Task {
			defer { fetching = false }
			while let window = latest, !Task.isCancelled {
				let (reset, entry) = receiver.next(in: window)
				if reset {
					buffer.reset()
					onReset?()
				}
				guard let entry, let attachment = attachments[entry.id] else { return }
				if let data = try? await attachment.load(Data.self), data.count == entry.size,
					RelayChannel.sha256(data) == entry.sha256 {
					buffer.append([UInt8](data))
				}
				// A chunk that failed to load or verify is skipped: MPEG-TS picks up at the next one.
				receiver.advance(past: entry.seq)
			}
		}
	}
}
