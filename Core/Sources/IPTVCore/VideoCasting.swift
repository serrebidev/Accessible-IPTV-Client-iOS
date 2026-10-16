import Foundation

/// Rules shared by the device's HLS converter and its small, token-protected HTTP server.
public enum VideoCasting {
	public static func file(for path: String, token: String) -> String? {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false)
		guard parts.count == 3, parts[0].isEmpty, parts[1] == token else { return nil }
		let name = String(parts[2])
		guard !name.hasPrefix("."), !name.contains(".."),
			name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
			name.hasSuffix(".m3u8") || name.hasSuffix(".ts") else { return nil }
		return name
	}

	public static func output(directory: String, baseURL: String, tracks: [String]) throws -> String {
		guard !tracks.isEmpty, tracks.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
			(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 47
		} }), !directory.contains("\""), !baseURL.contains("\"") else { throw CocoaError(.fileWriteInvalidFileName) }
		// a22's PCR snapshots break when a second encoded ES arrives; isolate audio and video.
		return ":sout=#transcode{acodec=mp4a,aenc=avcodec{codec=aac,aac-profile=low},ab=128,channels=2,samplerate=48000}:transcode{vcodec=h264,venc=avcodec{codec=h264_videotoolbox,keyint=60,bframes=0},vb=2500,fps=30,deinterlace,soverlay}:hls{variants=\"{\(tracks.joined(separator: ","))}\",seg-type=ts,out-dir=\"\(directory)\",base-url=\"\(baseURL)\",num-seg=6,seg-len=2,pace=true}"
	}

	/// VLC a22 marks a bounded sliding window as EVENT; receivers must treat it as live.
	public static func completeManifest(_ data: Data) -> Bool {
		let text = String(decoding: data, as: UTF8.self)
		guard text.hasPrefix("#EXTM3U\n"), text.hasSuffix("\n"), let last = text.split(separator: "\n").last else { return false }
		return last.hasSuffix(".ts") || last.hasSuffix(".m3u8") || last == "#EXT-X-ENDLIST"
	}

	public static func liveManifest(_ data: Data) -> Data {
		let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
		let missing = [("VIDEO", "video"), ("AUDIO", "audio"), ("SUBTITLES", "subtitles")].filter { type, group in
			!lines.contains { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=\(type)") && $0.contains("GROUP-ID=\"\(group)\"") }
		}
		return Data(lines.filter { !$0.hasPrefix("#EXT-X-PLAYLIST-TYPE:") }.map { line in
			guard line.hasPrefix("#EXT-X-STREAM-INF:") else { return line }
			// a22 also references rendition groups that it never generated for muxed variants.
			return missing.reduce(line) { $0.replacingOccurrences(of: ",\($1.0)=\"\($1.1)\"", with: "") }
		}.joined(separator: "\n").utf8)
	}
}
