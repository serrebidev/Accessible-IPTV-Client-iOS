import Foundation
import IPTVCore
import Network
import XCTest
@testable import AccessibleIPTV

final class ProviderConnectionTests: XCTestCase {
	@MainActor
	func testRecordingCannotOpenASecondStreamDuringPlayback() async throws {
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
		let recording = Task {
			for try await _ in reader.chunks { }
		}
		try await wait { server.requests == 1 }
		recording.cancel()
		_ = await recording.result
		// close() must finish even when the recording task has already been cancelled.
		let closing = Task { await reader.close() }
		closing.cancel()
		await closing.value
		try await wait { server.connections.isEmpty }
		XCTAssertEqual(server.requests, 1)
	}

	@MainActor
	func testResumeDuringCastStartupDoesNotReopenTheProvider() async throws {
		let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mpeg2-mp2", withExtension: "ts"))
		let server = try StreamServer(body: Data(contentsOf: fixture))
		let url = try await server.url()
		let player = PlayerController(request: PlayRequest(url: url, title: "Test", channelKey: "", catchup: false,
			channel: nil, archiveStart: nil, archiveStop: nil))
		defer { player.close(); server.stop() }
		player.start()
		try await wait { !player.player.videoTracks.isEmpty && !player.player.audioTracks.isEmpty }
		player.prepareAirPlay()
		try await wait { server.requests == 1 && server.connections.isEmpty }
		player.pause()
		player.resume()
		try await wait { server.requests == 2 }
		player.pause()
		player.resume()
		try await Task.sleep(nanoseconds: 1_000_000_000)
		XCTAssertEqual(server.requests, 2, "Resuming conversion must not restart the direct provider reader")
		player.close()
		let stopped = await PlaybackTeardown.ready()
		XCTAssertTrue(stopped)
	}

	@MainActor
	private func wait(_ condition: () -> Bool) async throws {
		let deadline = Date().addingTimeInterval(20)
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
	private(set) var requests = 0
	private(set) var connections: [ObjectIdentifier: NWConnection] = [:]

	init(body: Data) throws {
		self.body = body
		listener = try NWListener(using: .tcp, on: .any)
		listener.newConnectionHandler = { [weak self] connection in
			Task { @MainActor in self?.accept(connection) }
		}
		listener.start(queue: .main)
	}

	func url() async throws -> String {
		let deadline = Date().addingTimeInterval(10)
		while listener.port == nil {
			guard Date() < deadline else { throw URLError(.timedOut) }
			try await Task.sleep(nanoseconds: 50_000_000)
		}
		return "http://127.0.0.1:\(listener.port!.rawValue)/live.ts"
	}

	func stop() {
		listener.cancel()
		for connection in connections.values { connection.cancel() }
		connections.removeAll()
	}

	private func accept(_ connection: NWConnection) {
		connections[ObjectIdentifier(connection)] = connection
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
