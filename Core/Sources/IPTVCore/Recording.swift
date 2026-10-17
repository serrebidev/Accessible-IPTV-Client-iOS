import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Recording rules shared by the app's recorder: the copy loop, the ended-early check,
/// scheduled entries and file names.
public enum Recording {
	/// A scheduled recording; JSON keys match the Android app.
	public struct Scheduled: Codable, Hashable, Identifiable {
		public let id: Int
		public let channelKey: String
		public let name: String
		public let title: String
		public let start: Int64
		public let end: Int64
		enum CodingKeys: String, CodingKey { case id, channelKey = "ch", name = "n", title = "t", start = "s", end = "e" }

		public init(id: Int, channelKey: String, name: String, title: String, start: Int64, end: Int64) {
			self.id = id; self.channelKey = channelKey; self.name = name; self.title = title; self.start = start; self.end = end
		}

		public init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			id = try c.decode(Int.self, forKey: .id); channelKey = try c.decode(String.self, forKey: .channelKey)
			name = try c.decode(String.self, forKey: .name); title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
			start = try c.decode(Int64.self, forKey: .start); end = try c.decode(Int64.self, forKey: .end)
		}
	}

	/// [start, end] widened by the padding in Settings (desktop: 0 minutes before, 2 after).
	public static func padded(id: Int, channel: Channel, title: String, start: Int64, end: Int64, preMinutes: Int, postMinutes: Int) -> Scheduled {
		Scheduled(id: id, channelKey: channel.key, name: channel.name, title: title,
			start: start - Int64(preMinutes) * 60_000, end: end + Int64(postMinutes) * 60_000)
	}

	/// Desktop _catchup_download_is_truncated: some providers close a catch-up file part-way
	/// and the copy looks finished. Short by more than 10% of the programme = ended early.
	public static func endedEarly(writtenMs: Int64?, expectMs: Int64) -> Bool {
		guard expectMs > 0, let w = writtenMs else { return false }
		return w < expectMs * 9 / 10
	}

	/// "Channel - Title 14 Oct 2026 20-00.ts" without characters file systems refuse.
	public static func fileName(label: String, at ms: Int64) -> String {
		let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
		let clean = String(label.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
		let stamp = String(Format.dateTime(ms).unicodeScalars.map { CharacterSet(charactersIn: "\\/:").contains($0) ? "-" : Character($0) })
		return "\(clean) \(stamp).ts"
	}

	/// [name] with "-2", "-3" and so on before the extension while [taken] says the name is
	/// already there. The name comes from the minute and the channel, so recording a channel
	/// twice in a minute would otherwise write both to one file and empty the first.
	public static func freeFileName(_ name: String, taken: (String) -> Bool) -> String {
		let dot = name.lastIndex(of: ".")
		let base = dot.map { String(name[..<$0]) } ?? name
		let ext = dot.map { String(name[$0...]) } ?? ""
		var out = name
		var n = 2
		while taken(out) {
			out = "\(base)-\(n)\(ext)"
			n += 1
		}
		return out
	}

	/// Copies [open]'s stream through [write] until [done]. With [reconnect], a dropped or
	/// ended stream is opened again after [pauseMs] and appended; [maxMisses] tries in a row
	/// without a byte end it. True when anything was written.
	public static func copy(
		open: () throws -> AsyncThrowingStream<Data, Error>,
		write: (Data) throws -> Void,
		close: () async -> Void = {},
		reconnect: Bool,
		pauseMs: UInt64 = 2_000,
		maxMisses: Int = 10,
		done: () -> Bool
	) async -> Bool {
		var wrote = false
		var misses = 0
		while !done() && !Task.isCancelled {
			var got = false
			do {
				for try await chunk in try open() {
					try write(chunk)
					wrote = true
					got = true
					if done() || Task.isCancelled { break }
				}
			} catch {
				// A dropped connection: below, the same as the server ending the stream.
			}
			await close()
			if !reconnect || done() || Task.isCancelled { break }
			misses = got ? 0 : misses + 1
			if misses >= maxMisses { break }
			do { try await Task.sleep(nanoseconds: pauseMs * 1_000_000) } catch { break }
		}
		return wrote
	}

	/// A recording transport. Always await close(), even after cancellation or an early exit.
	public final class Reader {
		public let chunks: AsyncThrowingStream<Data, Error>
		private let session: URLSession
		private let delegate: ChunkDelegate

		public init(_ url: String, headers: [String: String]) throws {
			var r = try Net.request(url, headers: headers)
			r.timeoutInterval = 30
			let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
			chunks = stream
			delegate = ChunkDelegate(cont)
			session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
			let session = session
			let task = session.dataTask(with: r)
			cont.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
			task.resume()
		}

		public func close() async {
			session.invalidateAndCancel()
			await delegate.waitForClose()
		}
	}

	private final class ChunkDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
		let cont: AsyncThrowingStream<Data, Error>.Continuation
		private let lock = NSLock()
		private var invalidated = false
		private var waiters: [CheckedContinuation<Void, Never>] = []
		init(_ c: AsyncThrowingStream<Data, Error>.Continuation) { cont = c }

		func waitForClose() async {
			await withCheckedContinuation { continuation in
				lock.lock()
				if invalidated { lock.unlock(); continuation.resume() }
				else { waiters.append(continuation); lock.unlock() }
			}
		}

		func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
			lock.lock()
			invalidated = true
			let pending = waiters
			waiters.removeAll()
			lock.unlock()
			pending.forEach { $0.resume() }
		}

		func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
			if let h = response as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
				cont.finish(throwing: NetError.status(h.statusCode))
				completionHandler(.cancel)
			} else {
				completionHandler(.allow)
			}
		}

		func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { cont.yield(data) }

		func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
			if let error { cont.finish(throwing: error) } else { cont.finish() }
			s.finishTasksAndInvalidate()
		}
	}
}
