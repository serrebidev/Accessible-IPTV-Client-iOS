import SwiftUI

/// Offline user guide from help.md (one per language). "# " lines become headings so the
/// VoiceOver rotor can jump between topics.
struct HelpView: View {
	private struct Block: Identifiable {
		let id: Int
		let text: String
		let heading: Bool
	}

	private let blocks: [Block] = {
		guard let url = Bundle.main.url(forResource: "help", withExtension: "md"), let guide = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		var out: [Block] = []
		var current: [String] = []
		func flush() {
			let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				let h = text.hasPrefix("# ")
				out.append(Block(id: out.count, text: h ? String(text.dropFirst(2)) : text, heading: h))
			}
			current = []
		}
		for line in guide.components(separatedBy: .newlines) {
			if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { current.append(line) }
		}
		flush()
		return out
	}()

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				ForEach(blocks) { b in
					Text(b.text)
						.font(b.heading ? .title2 : .body)
						.frame(maxWidth: .infinity, alignment: .leading)
						.accessibilityAddTraits(b.heading ? .isHeader : [])
						#if os(tvOS)
						// The remote scrolls by moving focus, so every paragraph takes it.
						.focusable()
						#endif
				}
			}
			.padding()
		}
		.navigationTitle(L("help"))
	}
}
