import Foundation

/// Audio-track preference matching, ported from the desktop client's audio_tracks.py.
public enum AudioTracks {
	/// Wording providers use for audio description. Multilingual on purpose.
	public static let adKeywords = [
		"audio description", "audiodescription", "audio descriptive", "descriptive audio",
		"described video", "description", "descriptive", "described", "audiodeskription",
		"hoerfilm", "hörfilm", "audiodeskrypcja", "audiovision", "descripcion", "descripción",
		"descrizione", "descrição", "dvs", "ad", "visual impaired", "visually impaired",
	]

	/// Below this length a keyword must match whole words: "ad" never fires on "Radio".
	private static let compoundMin = 6

	/// Lower-case words. Unicode letters count as word characters ("hörfilm" stays one word).
	public static func tokens(_ text: String?) -> [String] {
		(text ?? "").lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
	}

	public static func matches(_ name: String?, _ keyword: String?) -> Bool {
		let have = tokens(name), want = tokens(keyword)
		if have.isEmpty || want.isEmpty { return false }
		if have.count >= want.count {
			for i in 0...(have.count - want.count) where Array(have[i..<(i + want.count)]) == want { return true }
		}
		let joined = want.joined()
		return joined.count >= compoundMin && have.joined().contains(joined)
	}

	/// Index of the track to select, or -1 to leave the player's default.
	/// Order: the per-channel remembered name, the audio-description flag/keywords,
	/// then the user's own keywords, most wanted first.
	public static func choose(names: [String], describesVideo: [Bool], remembered: String?, preferAd: Bool, keywords: [String]) -> Int {
		if let r = remembered, !r.trimmingCharacters(in: .whitespaces).isEmpty,
		   let i = names.firstIndex(where: { $0.caseInsensitiveCompare(r) == .orderedSame }) { return i }
		if preferAd {
			if let i = describesVideo.firstIndex(of: true) { return i }
			if let i = names.firstIndex(where: { n in adKeywords.contains(where: { matches(n, $0) }) }) { return i }
		}
		for k in keywords { if let i = names.firstIndex(where: { matches($0, k) }) { return i } }
		return -1
	}
}
