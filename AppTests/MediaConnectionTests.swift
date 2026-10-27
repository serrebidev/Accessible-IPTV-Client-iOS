import Foundation
import IPTVCore
import Network
import XCTest
@testable import AccessibleIPTV

final class ProviderConnectionTests: XCTestCase {
	@MainActor
	func testRecordingCannotOpenASecondStreamDuringPlayback() async throws {
		PlaybackBackend.forced = .vlc
		defer { PlaybackBackend.forced = nil }
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let server = try StreamServer(body: Data(contentsOf: fixture))
		let url = try await server.url()
		let player = PlayerController(request: PlayRequest(url: url, title: "Test", channelKey: "", catchup: false,
			channel: nil, archiveStart: nil, archiveStop: nil))
		let recorder = RecorderCenter(prefs: Prefs())
		defer { player.close(); recorder.stopAll(); server.stop() }
		player.start()
		try await wait { server.requests == 1 }
		recorder.download(url, name: "Test", title: "")
		try await wait { recorder.active.isEmpty }
		XCTAssertEqual(server.requests, 1, "Recording must not open another provider reader")
		XCTAssertEqual(server.peakConnections, 1)
		XCTAssertEqual(AppModel.shared.status, L("single_connection_busy"))
		player.close()
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
		try await wait { server.connections.isEmpty }
	}

	@MainActor
	func testCancelledRecordingWaitsForHTTPTransportToClose() async throws {
		let server = try StreamServer(body: Data(repeating: 0x47, count: 188 * 64))
		defer { server.stop() }
		let url = try await server.url()
		let reader = try Recording.Reader(url, headers: [:])
		let cancelled = expectation(description: "Recording iteration cancelled")
		let recording = Task {
			defer { cancelled.fulfill() }
			for try await _ in reader.chunks { }
		}
		try await wait { server.requests == 1 }
		recording.cancel()
		await fulfillment(of: [cancelled], timeout: 10)
		// close() must finish even when the recording task has already been cancelled.
		let closed = expectation(description: "Recording HTTP transport invalidated")
		let closing = Task { await reader.close(); closed.fulfill() }
		closing.cancel()
		await fulfillment(of: [closed], timeout: 10)
		try await wait { server.connections.isEmpty }
		XCTAssertEqual(server.requests, 1)
	}

	@MainActor
	func testResumeDuringCastStartupDoesNotReopenTheProvider() async throws {
		PlaybackBackend.forced = .vlc
		defer { PlaybackBackend.forced = nil }
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let server = try StreamServer(body: Data(contentsOf: fixture))
		let url = try await server.url()
		let player = PlayerController(request: PlayRequest(url: url, title: "Test", channelKey: "", catchup: false,
			channel: nil, archiveStart: nil, archiveStop: nil))
		defer { player.close(); server.stop() }
		player.start()
		try await wait(seconds: 45) { !player.player.videoTracks.isEmpty && !player.player.audioTracks.isEmpty }
		player.prepareAirPlay()
		try await wait { server.requests == 1 && server.connections.isEmpty }
		player.pause()
		player.resume()
		try await wait { server.requests >= 2 }
		player.pause()
		player.resume()
		try await Task.sleep(nanoseconds: 1_000_000_000)
		XCTAssertEqual(server.peakConnections, 1, "Cast handoffs and reconnects must never overlap provider readers")
		player.close()
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
	}

	@MainActor
	private func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(seconds)
		while !condition() {
			guard Date() < deadline else { throw URLError(.timedOut) }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
	}
}

/// A streaming provider whose real HTTP requests and open sockets can be counted.
@MainActor
private final class StreamServer {
	private let listener: NWListener
	private let body: Data
	private var port: UInt16?
	private(set) var requests = 0
	private(set) var peakConnections = 0
	private(set) var connections: [ObjectIdentifier: NWConnection] = [:]

	init(body: Data) throws {
		self.body = body
		listener = try NWListener(using: .tcp, on: .any)
		listener.newConnectionHandler = { [weak self] connection in
			Task { @MainActor in self?.accept(connection) }
		}
		listener.stateUpdateHandler = { [weak self] state in
			Task { @MainActor in
				guard let self, case .ready = state, let port = self.listener.port, port.rawValue != 0 else { return }
				self.port = port.rawValue
			}
		}
		listener.start(queue: .main)
	}

	func url() async throws -> String {
		let deadline = Date().addingTimeInterval(10)
		while port == nil {
			guard Date() < deadline else { throw URLError(.timedOut) }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		return "http://127.0.0.1:\(port!)/live.ts"
	}

	func stop() {
		listener.cancel()
		for connection in connections.values { connection.cancel() }
		connections.removeAll()
	}

	private func accept(_ connection: NWConnection) {
		connections[ObjectIdentifier(connection)] = connection
		peakConnections = max(peakConnections, connections.count)
		connection.start(queue: .main)
		receive(connection, request: Data())
	}

	private func receive(_ connection: NWConnection, request: Data?) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
			Task { @MainActor in
				guard let self else { return }
				if complete || error != nil { self.close(connection); return }
				if var request {
					if let data { request.append(data) }
					guard request.count <= 16_384 else { self.close(connection); return }
					if request.range(of: Data("\r\n\r\n".utf8)) != nil {
						self.requests += 1
						print("Test provider request \(self.requests): \(self.connections.count) active connections")
						connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8),
							completion: .contentProcessed { _ in })
						self.pump(connection)
						self.receive(connection, request: nil)
					} else { self.receive(connection, request: request) }
				} else { self.receive(connection, request: nil) }
			}
		}
	}

	private func pump(_ connection: NWConnection) {
		guard connections[ObjectIdentifier(connection)] != nil else { return }
		connection.send(content: body, completion: .contentProcessed { [weak self] error in
			Task { @MainActor in
				guard let self else { return }
				if error != nil { self.close(connection); return }
				try? await Task.sleep(nanoseconds: 100_000_000)
				self.pump(connection)
			}
		})
	}

	private func close(_ connection: NWConnection) {
		connection.cancel()
		connections.removeValue(forKey: ObjectIdentifier(connection))
	}
}
