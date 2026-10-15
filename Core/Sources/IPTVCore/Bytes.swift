import Foundation
#if canImport(Compression)
import Compression
#endif

/// A body read in chunks: guides and VOD lists run past 100 MB and never sit in memory whole.
public protocol ByteSource: AnyObject {
	/// The next chunk, or nil at the end.
	func next() throws -> Data?
}

public enum ByteError: LocalizedError {
	case endedEarly, gzipUnsupported, gzipBroken
	public var errorDescription: String? {
		switch self {
		case .endedEarly: return "Guide ended early"
		case .gzipUnsupported: return "Compressed files are not supported here"
		case .gzipBroken: return "Broken compressed file"
		}
	}
}

/// Chunks of an in-memory buffer (tests, small bodies).
public final class DataSource: ByteSource {
	private var chunks: [Data]
	public init(_ data: Data, chunk: Int = 256 * 1024) {
		var c: [Data] = []
		var i = 0
		while i < data.count { c.append(data.subdata(in: i..<min(data.count, i + chunk))); i += chunk }
		chunks = c
	}
	public func next() throws -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
}

/// A file read 256 KB at a time; [deleteWhenDone] removes a downloaded temp file afterwards.
public final class FileSource: ByteSource {
	private let handle: FileHandle
	private let url: URL
	private let deleteWhenDone: Bool
	public init(_ url: URL, deleteWhenDone: Bool = false) throws {
		self.url = url
		self.deleteWhenDone = deleteWhenDone
		handle = try FileHandle(forReadingFrom: url)
	}
	public func next() throws -> Data? {
		let d = try handle.read(upToCount: 256 * 1024) ?? Data()
		return d.isEmpty ? nil : d
	}
	deinit {
		try? handle.close()
		if deleteWhenDone { try? FileManager.default.removeItem(at: url) }
	}
}

/// Unwraps gzip when the first two bytes say so (guides are often .xml.gz served as plain bytes).
public func sniffGzip(_ src: ByteSource) throws -> ByteSource {
	let first = try src.next()
	let replay = ReplaySource(first, src)
	guard let f = first, f.count >= 2, f[f.startIndex] == 0x1f, f[f.startIndex + 1] == 0x8b else { return replay }
	#if canImport(Compression)
	return Gunzip(replay)
	#else
	throw ByteError.gzipUnsupported
	#endif
}

private final class ReplaySource: ByteSource {
	private var first: Data?
	private let rest: ByteSource
	init(_ first: Data?, _ rest: ByteSource) { self.first = first; self.rest = rest }
	func next() throws -> Data? {
		if let f = first { first = nil; return f }
		return try rest.next()
	}
}

/// Whole-buffer gunzip for small bodies; non-gzip data comes back unchanged.
public func gunzipIfNeeded(_ data: Data) throws -> Data {
	guard data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
	let src = try sniffGzip(DataSource(data))
	var out = Data()
	while let c = try src.next() { out.append(c) }
	return out
}

#if canImport(Compression)
/// Streaming gzip: parses the member header by hand and feeds raw DEFLATE to Compression
/// (COMPRESSION_ZLIB is raw deflate). Concatenated members are followed.
final class Gunzip: ByteSource {
	private let inner: ByteSource
	private var input: [UInt8] = []
	private var pos = 0
	private var innerEnded = false
	private var inHeader = true
	private var finished = false
	private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
	private var streamOpen = false
	/// One output buffer for the whole stream, not 256 KB allocated per chunk.
	private var out = [UInt8](repeating: 0, count: 256 * 1024)

	init(_ inner: ByteSource) { self.inner = inner }

	deinit {
		if streamOpen { compression_stream_destroy(stream) }
		stream.deallocate()
	}

	/// More input; false at the end of the inner source.
	private func fill() throws -> Bool {
		if innerEnded { return false }
		guard let d = try inner.next() else { innerEnded = true; return false }
		input = Array(input[pos...]) + [UInt8](d)
		pos = 0
		return true
	}

	private func need(_ n: Int) throws -> Bool {
		while input.count - pos < n { if try !fill() { return false } }
		return true
	}

	/// Skips the gzip member header. Returns false at a clean end of input.
	private func header() throws -> Bool {
		guard try need(10) else {
			if input.count - pos == 0 { return false }
			throw ByteError.gzipBroken
		}
		guard input[pos] == 0x1f, input[pos + 1] == 0x8b, input[pos + 2] == 8 else { throw ByteError.gzipBroken }
		let flags = input[pos + 3]
		pos += 10
		if flags & 4 != 0 { // FEXTRA
			guard try need(2) else { throw ByteError.gzipBroken }
			let len = Int(input[pos]) | Int(input[pos + 1]) << 8
			pos += 2
			guard try need(len) else { throw ByteError.gzipBroken }
			pos += len
		}
		for bit: UInt8 in [8, 16] where flags & bit != 0 { // FNAME, FCOMMENT: zero-terminated
			while true {
				guard try need(1) else { throw ByteError.gzipBroken }
				let b = input[pos]; pos += 1
				if b == 0 { break }
			}
		}
		if flags & 2 != 0 { guard try need(2) else { throw ByteError.gzipBroken }; pos += 2 } // FHCRC
		if streamOpen { compression_stream_destroy(stream) }
		guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ByteError.gzipBroken }
		streamOpen = true
		return true
	}

	func next() throws -> Data? {
		while !finished {
			if inHeader {
				guard try header() else { finished = true; return nil }
				inHeader = false
			}
			if pos == input.count, try !fill() {
				// Input over: let the decoder flush; a member cut off here is an error.
				if let d = try process(final: true) { return d }
				throw ByteError.endedEarly
			}
			if let d = try process(final: false) { return d }
		}
		return nil
	}

	/// Runs the decoder over the buffered input. Data when it produced some; nil when it needs more.
	private func process(final: Bool) throws -> Data? {
		let avail = input.count - pos
		var consumed = 0
		var produced = 0
		var status = COMPRESSION_STATUS_OK
		input.withUnsafeBufferPointer { inp in
			out.withUnsafeMutableBufferPointer { o in
				stream.pointee.src_ptr = avail > 0 ? inp.baseAddress! + pos : UnsafePointer(o.baseAddress!)
				stream.pointee.src_size = avail
				stream.pointee.dst_ptr = o.baseAddress!
				stream.pointee.dst_size = o.count
				status = compression_stream_process(stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
				consumed = avail - stream.pointee.src_size
				produced = o.count - stream.pointee.dst_size
			}
		}
		pos += consumed
		if status == COMPRESSION_STATUS_ERROR { throw ByteError.gzipBroken }
		if status == COMPRESSION_STATUS_END {
			// 8-byte trailer (CRC, size), then maybe another member.
			_ = try need(8)
			pos = min(input.count, pos + 8)
			inHeader = true
		}
		if produced > 0 { return Data(out[0..<produced]) }
		if status == COMPRESSION_STATUS_END { return try next() }
		if final { return nil }
		return nil
	}
}
#endif
