#if os(iOS)
import Darwin
import Foundation
import Network
import VLCKit
import IPTVCore

/// One provider connection, converted on this device to H.264/AAC HLS for either receiver.
@MainActor
final class VideoRelay: NSObject, VLCMediaPlayerDelegate {
	let player = VLCMediaPlayer()
	private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
	private var listener: NWListener?
	private var connections: [ObjectIdentifier: NWConnection] = [:]
	private var monitor: Task<Void, Never>?
	private var manifests: [String: Data] = [:]
	private var completion: ((Result<URL, Error>) -> Void)?
	private var stopped = false
	private var live = false
	private(set) var url: URL?
	var onFailure: (() -> Void)?

	func start(source: String, tracks: [String], seconds: Double, subtitleID: String? = nil, subtitleFile: URL? = nil,
		live: Bool, completion: @escaping (Result<URL, Error>) -> Void) {
		self.completion = completion
		self.live = live
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			guard let address = Self.localAddress() else { throw URLError(.notConnectedToInternet) }
			let listener = try NWListener(using: .tcp, on: .any)
			self.listener = listener
			listener.newConnectionHandler = { [weak self] connection in
				Task { @MainActor in self?.accept(connection) }
			}
			listener.stateUpdateHandler = { [weak self] state in
				Task { @MainActor in
					guard let self, !self.stopped else { return }
					switch state {
					case .ready:
						guard let port = listener.port else { self.fail(URLError(.cannotConnectToHost)); return }
						self.convert(source: source, tracks: tracks, seconds: seconds, subtitleID: subtitleID,
							subtitleFile: subtitleFile, base: "http://\(address):\(port.rawValue)/\(self.token)")
					case .failed(let error): self.fail(error)
					default: break
					}
				}
			}
			listener.start(queue: .main)
		} catch { fail(error) }
	}

	private func convert(source: String, tracks: [String], seconds: Double, subtitleID: String?, subtitleFile: URL?, base: String) {
		do {
			let (plain, headers) = M3U.splitHeaders(source)
			guard let sourceURL = URL(string: plain), let media = VLCMedia(url: sourceURL),
				let outputURL = URL(string: base + "/index.m3u8") else { throw URLError(.badURL) }
			media.addOption(try VideoCasting.output(directory: directory.path, baseURL: base, tracks: tracks))
			media.addOption(":video-track-id=\(tracks[0])")
			if tracks.count > 1 { media.addOption(":audio-track-id=\(tracks[1])") }
			media.addOption(":sub-track-id=\(subtitleID ?? "none")")
			if let subtitleFile { media.addOption(":sub-file=\(subtitleFile.path)") }
			media.addOption(":http-user-agent=\(headers["User-Agent"] ?? Net.userAgent)")
			if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
			if let cookie = headers["Cookie"], let host = sourceURL.host { _ = media.storeCookie(cookie, forHost: host, path: "/") }
			media.addOption(":network-caching=1000")
			if seconds.isFinite, seconds > 0 { media.addOption(":start-time=\(seconds)") }
			player.delegate = self
			player.media = media
			PlaybackTeardown.play(player)
			monitor = Task { [weak self] in
				let deadline = ProcessInfo.processInfo.systemUptime + 40
				while !Task.isCancelled {
					guard let self, !self.stopped else { return }
					do {
						try self.prune()
						if self.url == nil, self.manifest("index.m3u8") != nil,
							let media = self.manifest("playlist-0-manifest.m3u8"),
							String(decoding: media, as: UTF8.self).components(separatedBy: "#EXTINF:").count >= 3 {
							self.url = outputURL
							let done = self.completion
							self.completion = nil
							done?(.success(outputURL))
						} else if self.url == nil, ProcessInfo.processInfo.systemUptime >= deadline {
							self.fail(URLError(.timedOut)); return
						}
					} catch { self.fail(error); return }
					do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
				}
			}
		} catch { fail(error) }
	}

	func stop() {
		guard !stopped else { return }
		stopped = true
		monitor?.cancel()
		completion = nil
		listener?.cancel()
		listener = nil
		connections.values.forEach { $0.cancel() }
		connections.removeAll()
		player.delegate = nil
		let teardown = PlaybackTeardown.stop(player)
		let directory = directory
		Task {
			await teardown.value
			try? FileManager.default.removeItem(at: directory)
		}
	}

	private func fail(_ error: Error) {
		guard !stopped else { return }
		let done = completion
		let failed = onFailure
		stop()
		if let done { done(.failure(error)) } else { failed?() }
	}

	nonisolated func mediaPlayerStateChanged(_ state: VLCMediaPlayerState) {
		Task { @MainActor in
			guard self.player.state == state else { return }
			if state == .error || state == .stopped && self.live { self.fail(URLError(.cannotDecodeContentData)) }
		}
	}

	/// a22 removes segments from its manifest but leaves their files on disk.
	private func prune() throws {
		let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
		let manifests = files.filter { $0.pathExtension == "m3u8" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
		for file in files where file.pathExtension == "ts" && !manifests.contains(file.lastPathComponent) {
			if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 30 {
				try FileManager.default.removeItem(at: file)
			}
		}
	}

	private func accept(_ connection: NWConnection) {
		guard !stopped, connections.count < 24 else { connection.cancel(); return }
		let id = ObjectIdentifier(connection)
		connections[id] = connection
		connection.stateUpdateHandler = { [weak self] state in
			Task { @MainActor in
				if case .cancelled = state { self?.connections.removeValue(forKey: id) }
				if case .failed = state { self?.connections.removeValue(forKey: id) }
			}
		}
		connection.start(queue: .main)
		DispatchQueue.main.asyncAfter(deadline: .now() + 10) { connection.cancel() }
		receive(connection, buffered: Data())
	}

	private func receive(_ connection: NWConnection, buffered: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
			Task { @MainActor in
				guard let self, !self.stopped else { connection.cancel(); return }
				var request = buffered
				if let data { request.append(data) }
				guard request.count <= 16_384 else { connection.cancel(); return }
				if request.range(of: Data("\r\n\r\n".utf8)) != nil { self.respond(connection, request: request) }
				else if complete || error != nil { connection.cancel() }
				else { self.receive(connection, buffered: request) }
			}
		}
	}

	private func respond(_ connection: NWConnection, request: Data) {
		let words = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
		guard words.count == 3, ["GET", "HEAD", "OPTIONS"].contains(words[0]),
			let name = VideoCasting.file(for: String(words[1]), token: token) else { connection.cancel(); return }
		let isManifest = name.hasSuffix(".m3u8")
		let raw = isManifest ? manifest(name) : try? Data(contentsOf: directory.appendingPathComponent(name))
		let body = raw ?? Data()
		let code = words[0] == "OPTIONS" ? "204 No Content" : raw == nil ? "404 Not Found" : "200 OK"
		let content = words[0] == "OPTIONS" ? Data() : body
		let header = "HTTP/1.1 \(code)\r\nContent-Type: \(isManifest ? "application/vnd.apple.mpegurl" : "video/mp2t")\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: Range\r\nConnection: close\r\n\r\n"
		var response = Data(header.utf8)
		if words[0] != "HEAD" { response.append(content) }
		connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
	}

	/// VLC rewrites manifests in place; a receiver must never see the truncated intermediate file.
	private func manifest(_ name: String) -> Data? {
		if let raw = try? Data(contentsOf: directory.appendingPathComponent(name)), VideoCasting.completeManifest(raw) {
			manifests[name] = VideoCasting.liveManifest(raw)
		}
		return manifests[name]
	}

	private static func localAddress() -> String? {
		var addresses: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&addresses) == 0 else { return nil }
		defer { freeifaddrs(addresses) }
		var cursor = addresses
		while let entry = cursor {
			defer { cursor = entry.pointee.ifa_next }
			guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
				String(cString: entry.pointee.ifa_name).hasPrefix("en"), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
				return String(cString: host)
			}
		}
		return nil
	}
}
#endif
