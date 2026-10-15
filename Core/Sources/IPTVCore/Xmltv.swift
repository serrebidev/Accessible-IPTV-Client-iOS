import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif

/// XMLTV helpers. Both run hundreds of thousands of times per guide import: no regex, no
/// date formatters.
public enum Xmltv {
	private static let stripTags: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265", "1080p", "720p", "backup", "raw"]

	/// "20261013143000 +0200" -> epoch ms UTC. Missing offset = UTC. Bad input = nil.
	public static func parseTime(_ value: String?) -> Int64? {
		guard let v0 = value else { return nil }
		let v = Array(v0.trimmingCharacters(in: .whitespaces).utf8)
		if v.count < 14 { return nil }
		func num(_ from: Int, _ len: Int) -> Int {
			var n = 0
			for i in from..<(from + len) {
				let d = Int(v[i]) - 48
				if d < 0 || d > 9 { return -1 }
				n = n * 10 + d
			}
			return n
		}
		let y = num(0, 4), mo = num(4, 2), d = num(6, 2), h = num(8, 2), mi = num(10, 2), s = num(12, 2)
		if y < 0 || !(1...12).contains(mo) || !(1...31).contains(d) || !(0...23).contains(h) || !(0...59).contains(mi) || !(0...60).contains(s) { return nil }
		if d > daysIn(month: mo, year: y) { return nil }
		let secs = Int64(daysFromCivil(y, mo, d)) * 86_400 + Int64(h * 3600 + mi * 60 + min(s, 59))
		let off = Array(String(decoding: v[14...], as: UTF8.self).trimmingCharacters(in: .whitespaces).utf8)
		var offsetSec = 0
		if off.count == 5, off[0] == UInt8(ascii: "+") || off[0] == UInt8(ascii: "-") {
			let digits = off[1...].map { Int($0) - 48 }
			if digits.allSatisfy({ (0...9).contains($0) }) {
				let oh = digits[0] * 10 + digits[1], om = digits[2] * 10 + digits[3]
				if (0...18).contains(oh) && (0...59).contains(om) { offsetSec = (oh * 3600 + om * 60) * (off[0] == UInt8(ascii: "-") ? -1 : 1) }
			}
		}
		return secs * 1000 - Int64(offsetSec) * 1000
	}

	static func daysIn(month: Int, year: Int) -> Int {
		switch month {
		case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
		case 4, 6, 9, 11: return 30
		default: return 31
		}
	}

	/// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil).
	static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
		let y = m <= 2 ? y0 - 1 : y0
		let era = (y >= 0 ? y : y - 399) / 400
		let yoe = y - era * 400
		let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
		let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
		return era * 146_097 + doe - 719_468
	}

	/// Name key for matching channels to guide entries when tvg-id is missing:
	/// drops a "UK:" style prefix, quality tags and punctuation.
	public static func nameKey(_ name: String) -> String {
		let chars = Array(name)
		// A 2-3 letter country prefix followed by ":" or "|".
		var start = 0
		var i = 0
		while i < chars.count && i < 3 && chars[i].isLetter && chars[i].isASCII { i += 1 }
		if i >= 2 {
			var j = i
			while j < chars.count && chars[j].isWhitespace { j += 1 }
			if j < chars.count && (chars[j] == ":" || chars[j] == "|") {
				j += 1
				while j < chars.count && chars[j].isWhitespace { j += 1 }
				start = j
			}
		}
		var out = ""
		var word = ""
		func flush() {
			if !word.isEmpty {
				if !stripTags.contains(word) { out += word }
				word = ""
			}
		}
		for k in start..<max(start, chars.count) {
			let c = chars[k]
			if c.isLetter || c.isNumber { word += c.lowercased() } else { flush() }
		}
		flush()
		return out
	}
}

/// A small streaming XML pull reader for XMLTV: elements, attributes, text, entities,
/// CDATA, comments. It reads [ByteSource] chunks, so a gzip guide is parsed as it inflates.
/// Not a validating parser; XMLTV is machine-written. Text runs are found with memchr and
/// decoded only when asked for; [skipElement] jumps over an element without tokenizing it,
/// which is what keeps a national guide (most of it unmatched) cheap.
public final class XmlPull {
	public enum Event: Equatable { case start, end, text, eof }

	public private(set) var event: Event = .eof
	/// Tag name for start/end.
	public private(set) var name = ""
	public private(set) var attrs: [String: String] = [:]

	/// Decoded text for a text event (decoded on first use).
	public var text: String {
		if let t = textCache { return t }
		let t = string(textBytes)
		textCache = t
		return t
	}

	private let src: ByteSource
	private var buf: [UInt8] = []
	private var pos = 0
	private var ended = false
	private var pendingEnd: String?
	private var latin1 = false
	private var textBytes: [UInt8] = []
	private var textCache: String?

	private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), amp = UInt8(ascii: "&")

	public init(_ src: ByteSource) { self.src = src }

	/// At least one unread byte in [buf]; false at the end of input.
	@inline(__always) private func fill() throws -> Bool {
		if pos < buf.count { return true }
		if ended { return false }
		while let d = try src.next() {
			if d.isEmpty { continue }
			buf = [UInt8](d)
			pos = 0
			return true
		}
		ended = true
		return false
	}

	/// Appends the next chunk after the unread bytes (lookahead across a chunk boundary).
	private func more() throws -> Bool {
		if ended { return false }
		while let d = try src.next() {
			if d.isEmpty { continue }
			var nb = [UInt8]()
			nb.reserveCapacity(buf.count - pos + d.count)
			nb.append(contentsOf: buf[pos...])
			nb.append(contentsOf: d)
			buf = nb
			pos = 0
			return true
		}
		ended = true
		return false
	}

	/// Index of [b] in [buf] at or after [from], or nil.
	@inline(__always) private func find(_ b: UInt8, from: Int) -> Int? {
		buf.withUnsafeBufferPointer { p -> Int? in
			guard from < p.count, let base = p.baseAddress, let hit = memchr(base + from, Int32(b), p.count - from) else { return nil }
			return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
		}
	}

	@inline(__always) private func peek() throws -> UInt8? { try fill() ? buf[pos] : nil }

	private func string(_ bytes: [UInt8]) -> String {
		let s = latin1 ? String(bytes.map { Character(UnicodeScalar($0)) }) : String(decoding: bytes, as: UTF8.self)
		return bytes.contains(XmlPull.amp) ? XmlPull.decodeEntities(s) : s
	}

	/// Everything up to [end] (1-3 bytes), consumed with it.
	private func until(_ end: [UInt8]) throws -> [UInt8] {
		var acc: [UInt8] = []
		let last = end[end.count - 1]
		while true {
			guard try fill() else { throw ByteError.endedEarly }
			if let i = find(last, from: pos) {
				acc.append(contentsOf: buf[pos...i])
				pos = i + 1
				if acc.count >= end.count && acc.suffix(end.count).elementsEqual(end) {
					acc.removeLast(end.count)
					return acc
				}
			} else {
				acc.append(contentsOf: buf[pos...])
				pos = buf.count
			}
		}
	}

	private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

	@discardableResult
	public func next() throws -> Event {
		if let e = pendingEnd {
			pendingEnd = nil
			name = e
			event = .end
			return event
		}
		textCache = nil
		while true {
			guard try fill() else { event = .eof; return event }
			if buf[pos] != XmlPull.lt {
				textBytes.removeAll(keepingCapacity: true)
				while true {
					if let i = find(XmlPull.lt, from: pos) {
						textBytes.append(contentsOf: buf[pos..<i])
						pos = i
						break
					}
					textBytes.append(contentsOf: buf[pos...])
					pos = buf.count
					guard try fill() else { break }
				}
				event = .text
				return event
			}
			pos += 1
			guard let c = try peek() else { throw ByteError.endedEarly }
			if c == XmlPull.slash {
				pos += 1
				name = String(decoding: try until([XmlPull.gt]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
				event = .end
				return event
			}
			if c == UInt8(ascii: "?") {
				let decl = String(decoding: try until(Array("?>".utf8)), as: UTF8.self).lowercased()
				if decl.hasPrefix("?xml") && (decl.contains("8859-1") || decl.contains("latin") || decl.contains("1252")) { latin1 = true }
				continue
			}
			if c == UInt8(ascii: "!") {
				pos += 1
				if try peek() == UInt8(ascii: "-") {
					_ = try until(Array("-->".utf8))
					continue
				}
				if try peek() == UInt8(ascii: "[") {
					// <![CDATA[ ... ]]>
					_ = try until([UInt8(ascii: "[")]) // the "[" of "[CDATA["
					_ = try until([UInt8(ascii: "[")])
					let raw = try until(Array("]]>".utf8))
					textBytes = raw
					textCache = latin1 ? String(raw.map { Character(UnicodeScalar($0)) }) : String(decoding: raw, as: UTF8.self)
					event = .text
					return event
				}
				// DOCTYPE and friends, with an optional [internal subset].
				var depth = 0
				while let d = try peek() {
					pos += 1
					if d == UInt8(ascii: "[") { depth += 1 } else if d == UInt8(ascii: "]") { depth -= 1 } else if d == XmlPull.gt && depth <= 0 { break }
				}
				continue
			}
			// Start tag.
			var nameBytes: [UInt8] = []
			while let d = try peek(), !XmlPull.isSpace(d), d != XmlPull.slash, d != XmlPull.gt { nameBytes.append(d); pos += 1 }
			name = String(decoding: nameBytes, as: UTF8.self)
			attrs = [:]
			while true {
				while let d = try peek(), XmlPull.isSpace(d) { pos += 1 }
				guard let d = try peek() else { throw ByteError.endedEarly }
				pos += 1
				if d == XmlPull.gt { break }
				if d == XmlPull.slash {
					guard try peek() == XmlPull.gt else { throw ByteError.endedEarly }
					pos += 1
					pendingEnd = name
					break
				}
				var key: [UInt8] = [d]
				while let e = try peek(), e != UInt8(ascii: "="), !XmlPull.isSpace(e), e != XmlPull.gt, e != XmlPull.slash { key.append(e); pos += 1 }
				while let e = try peek(), XmlPull.isSpace(e) { pos += 1 }
				guard try peek() == UInt8(ascii: "=") else { continue } // attribute without a value
				pos += 1
				while let e = try peek(), XmlPull.isSpace(e) { pos += 1 }
				guard let q = try peek() else { throw ByteError.endedEarly }
				pos += 1
				let value: [UInt8]
				if q == UInt8(ascii: "\"") || q == UInt8(ascii: "'") {
					value = try until([q])
				} else {
					var v: [UInt8] = [q]
					while let e = try peek(), !XmlPull.isSpace(e), e != XmlPull.gt { v.append(e); pos += 1 }
					value = v
				}
				attrs[String(decoding: key, as: UTF8.self)] = string(value)
			}
			event = .start
			return event
		}
	}

	/// After a start tag: jumps to its end tag without tokenizing what is inside.
	/// ponytail: finds the first "</name" after the start, so it is for elements that never
	/// nest themselves (programme, channel) and have no "</name" inside CDATA.
	public func skipElement() throws {
		guard event == .start else { return }
		if pendingEnd != nil { try next(); return }
		let tag = name
		let pattern = Array("</\(tag)".utf8)
		while true {
			guard try fill() else { throw ByteError.endedEarly }
			guard let i = find(XmlPull.lt, from: pos) else { pos = buf.count; continue }
			pos = i
			while buf.count - pos <= pattern.count { guard try more() else { throw ByteError.endedEarly } }
			if buf[pos..<(pos + pattern.count)].elementsEqual(pattern) {
				let after = buf[pos + pattern.count]
				if after == XmlPull.gt || XmlPull.isSpace(after) {
					pos += pattern.count
					_ = try until([XmlPull.gt])
					name = tag
					event = .end
					textCache = nil
					return
				}
			}
			pos += 1
		}
	}

	/// After a start tag: the element's text, nested markup skipped, positioned on its end tag.
	public func nextText() throws -> String {
		guard event == .start else { return "" }
		if pendingEnd != nil { try next(); return "" }
		var out = ""
		var depth = 1
		while depth > 0 {
			switch try next() {
			case .text: out += text
			case .start: depth += 1
			case .end: depth -= 1
			case .eof: throw ByteError.endedEarly
			}
		}
		return out
	}

	static func decodeEntities(_ s: String) -> String {
		var out = ""
		var i = s.startIndex
		while i < s.endIndex {
			let c = s[i]
			if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
				let ent = s[s.index(after: i)..<semi]
				var rep: String?
				switch ent {
				case "amp": rep = "&"
				case "lt": rep = "<"
				case "gt": rep = ">"
				case "quot": rep = "\""
				case "apos": rep = "'"
				default:
					if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
						rep = UInt32(ent.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) }
					} else if ent.hasPrefix("#") {
						rep = UInt32(ent.dropFirst()).flatMap(UnicodeScalar.init).map { String(Character($0)) }
					}
				}
				if let r = rep {
					out += r
					i = s.index(after: semi)
					continue
				}
			}
			out.append(c)
			i = s.index(after: i)
		}
		return out
	}
}
