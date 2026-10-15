import Foundation
import VLCKit

private struct Configuration {
	let producer: Bool
	let url: URL
	let port: Int?
	let seconds: Int
	let seekAfter: Int?
	let seekTo: Double?

	init?(_ arguments: [String]) {
		guard let mode = arguments.first, mode == "producer" || mode == "consumer",
			(mode == "producer" ? [4, 6].contains(arguments.count) : arguments.count == 3),
			let url = URL(string: arguments[1]), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			url.host != nil, let seconds = Int(arguments[mode == "producer" ? 3 : 2]), (1...180).contains(seconds) else { return nil }
		let port = mode == "producer" ? Int(arguments[2]) : nil
		if mode == "producer", port == nil || !(1024...65535).contains(port!) { return nil }
		let seekAfter = arguments.count == 6 ? Int(arguments[4]) : nil
		let seekTo = arguments.count == 6 ? Double(arguments[5]) : nil
		if arguments.count == 6 {
			guard let seekAfter, let seekTo, seekAfter > 0, seekAfter < seconds,
				seekTo.isFinite, seekTo >= 0, seekTo <= Double(Int32.max) / 1000 else { return nil }
		}
		producer = mode == "producer"
		self.url = url
		self.port = port
		self.seconds = seconds
		self.seekAfter = seekAfter
		self.seekTo = seekTo
	}
}

private struct Sample: Encodable {
	let event: String
	let role: String
	let elapsed: Double
	let state: String
	let time: Int32
	let readBytes: UInt64
	let demuxReadBytes: UInt64
	let decodedVideo: UInt64
	let decodedAudio: UInt64
	let success: Bool?
	let seekTo: Double?
	let progress: Double?
	let lastDecodedElapsed: Double?
	let continuous: Bool?
}

private struct DecodeProgress {
	private var firstTime: Double?
	private var video: UInt64 = 0
	private var audio: UInt64 = 0
	private var lastVideo: Double?
	private var lastAudio: Double?
	private(set) var progress: Double = 0
	private(set) var continuous = true
	var lastDecodedElapsed: Double? {
		guard let lastVideo, let lastAudio else { return nil }
		return min(lastVideo, lastAudio)
	}

	mutating func observe(time: Int32, video: UInt64, audio: UInt64, elapsed: Double, ended: Bool) {
		if firstTime == nil, video > 0, audio > 0 {
			firstTime = Double(time) / 1000
			lastVideo = elapsed
			lastAudio = elapsed
		}
		if let firstTime {
			if ended { continuous = false }
			if video > self.video { lastVideo = elapsed }
			if audio > self.audio { lastAudio = elapsed }
			if let lastDecodedElapsed, elapsed - lastDecodedElapsed > 3 { continuous = false }
			if video < self.video || audio < self.audio { continuous = false }
			progress = max(progress, Double(time) / 1000 - firstTime)
		}
		self.video = video
		self.audio = audio
	}

	func succeeded(at elapsed: Double) -> Bool {
		guard continuous, video >= 10, audio >= 10, progress >= 2,
			let lastDecodedElapsed else { return false }
		return elapsed - lastDecodedElapsed <= 3
	}
}

private func emit(_ sample: Sample) {
	let encoder = JSONEncoder()
	encoder.outputFormatting = [.sortedKeys]
	do {
		let data = try encoder.encode(sample)
		FileHandle.standardOutput.write(data)
		FileHandle.standardOutput.write(Data([10]))
	} catch {
		FileHandle.standardError.write(Data("Could not encode probe statistics.\n".utf8))
		exit(2)
	}
}

@MainActor
private final class ProbeDelegate: NSObject, VLCMediaPlayerDelegate {
	var hadError = false
	nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
		if newState == .error { Task { @MainActor in self.hadError = true } }
	}
}

private func stateName(_ state: VLCMediaPlayerState) -> String {
	switch state {
	case .nothingSpecial: return "nothingSpecial"
	case .opening: return "opening"
	case .playing: return "playing"
	case .paused: return "paused"
	case .stopped: return "stopped"
	case .stopping: return "stopping"
	case .error: return "error"
	@unknown default: return "unknown"
	}
}

@MainActor
private func run(_ config: Configuration) async -> Int32 {
	// A dedicated instance prevents inherited app configuration or another HTTP server binding.
	let player = VLCMediaPlayer(options: ["--http-host=127.0.0.1", "--vout=dummy", "--aout=dummy", "--ignore-config"])
	let delegate = ProbeDelegate()
	player.delegate = delegate
	guard let media = VLCMedia(url: config.url) else {
		FileHandle.standardError.write(Data("Could not create probe media.\n".utf8))
		return 2
	}
	media.addOption(":network-caching=500")
	media.addOption(":http-user-agent=\(config.producer ? "IPTVHostProbe/1" : "IPTVGuestProbe/1")")
	if let port = config.port {
		// The app relays MPEG-TS: whole 188-byte packets let a late joiner start at any chunk.
		media.addOption(":sout=#std{access=http{user=probe,pwd=probe-only,mime=video/mp2t},mux=ts,dst=127.0.0.1:\(port)/relay.ts}")
		media.addOption(":sout-all")
	}
	player.media = media
	let started = ProcessInfo.processInfo.systemUptime
	let deadline = started + Double(config.seconds)
	var sought = false
	var decoding = DecodeProgress()
	player.play()
	while ProcessInfo.processInfo.systemUptime < deadline {
		if !sought, let after = config.seekAfter, let target = config.seekTo,
			ProcessInfo.processInfo.systemUptime - started >= Double(after) {
			sought = true
			player.time = VLCTime(int: Int32(target * 1000))
			let stats = media.statistics
			emit(Sample(event: "seekRequested", role: "producer", elapsed: ProcessInfo.processInfo.systemUptime - started,
				state: stateName(player.state), time: player.time.intValue, readBytes: stats.readBytes,
				demuxReadBytes: stats.demuxReadBytes, decodedVideo: stats.decodedVideo,
				decodedAudio: stats.decodedAudio, success: nil, seekTo: target,
				progress: nil, lastDecodedElapsed: nil, continuous: nil))
		}
		let stats = media.statistics
		if !config.producer {
			decoding.observe(time: player.time.intValue, video: stats.decodedVideo, audio: stats.decodedAudio,
				elapsed: ProcessInfo.processInfo.systemUptime - started, ended: player.state == .stopped || player.state == .stopping)
		}
		emit(Sample(event: "sample", role: config.producer ? "producer" : "consumer",
			elapsed: ProcessInfo.processInfo.systemUptime - started, state: stateName(player.state),
			time: player.time.intValue, readBytes: stats.readBytes, demuxReadBytes: stats.demuxReadBytes,
			decodedVideo: stats.decodedVideo, decodedAudio: stats.decodedAudio, success: nil, seekTo: nil,
			progress: nil, lastDecodedElapsed: nil, continuous: nil))
		if delegate.hadError || player.state == .error { break }
		let remaining = deadline - ProcessInfo.processInfo.systemUptime
		if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(min(1, remaining) * 1_000_000_000)) }
	}
	let stats = media.statistics
	let elapsed = ProcessInfo.processInfo.systemUptime - started
	if !config.producer {
		decoding.observe(time: player.time.intValue, video: stats.decodedVideo, audio: stats.decodedAudio,
			elapsed: elapsed, ended: player.state == .stopped || player.state == .stopping)
	}
	let success = !delegate.hadError && player.state != .error && (config.producer
		? stats.demuxReadBytes > 0 : decoding.succeeded(at: elapsed))
	emit(Sample(event: "summary", role: config.producer ? "producer" : "consumer",
		elapsed: ProcessInfo.processInfo.systemUptime - started, state: stateName(player.state),
		time: player.time.intValue, readBytes: stats.readBytes, demuxReadBytes: stats.demuxReadBytes,
		decodedVideo: stats.decodedVideo, decodedAudio: stats.decodedAudio, success: success, seekTo: nil,
		progress: config.producer ? nil : decoding.progress,
		lastDecodedElapsed: config.producer ? nil : decoding.lastDecodedElapsed,
		continuous: config.producer ? nil : decoding.continuous))
	player.stop()
	player.delegate = nil
	return success ? 0 : 1
}

guard let config = Configuration(Array(CommandLine.arguments.dropFirst())) else {
	FileHandle.standardError.write(Data("Usage: RelayProbe producer <input-url> <output-port> <duration-seconds> [seek-after-seconds seek-to-seconds] | RelayProbe consumer <input-url> <duration-seconds>\nDuration: 1...180 seconds; output port: 1024...65535.\n".utf8))
	exit(2)
}
exit(await run(config))
