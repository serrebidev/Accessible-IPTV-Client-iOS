import SwiftUI
import IPTVCore

/// A row action: a VoiceOver custom action and the same entry in the long-press menu.
struct RowAction: Identifiable {
	let id = UUID()
	let label: String
	let run: () -> Void
	init(_ label: String, _ run: @escaping () -> Void) { self.label = label; self.run = run }
}

extension View {
	/// One row = one stop. VoiceOver reads [speech]; the secondary actions live in the
	/// VoiceOver Actions rotor and in a long-press (tvOS: hold Select) menu, so nobody swipes
	/// past a strip of small buttons on every row.
	func row(_ speech: String, actions: [RowAction]) -> some View {
		modifier(RowModifier(speech: speech, actions: actions))
	}
}

private struct RowModifier: ViewModifier {
	let speech: String
	let actions: [RowAction]
	/// After a long-press menu item runs, VoiceOver stays on the row it came from.
	@AccessibilityFocusState private var focused: Bool

	func body(content: Content) -> some View {
		if actions.isEmpty {
			content.accessibilityLabel(speech)
		} else {
			content
				.accessibilityLabel(speech)
				.accessibilityActions { ForEach(actions) { a in Button(a.label, action: a.run) } }
				.contextMenu { ForEach(actions) { a in Button(a.label) { a.run(); focused = true } } }
				.accessibilityHint(L("row_actions_hint"))
				.accessibilityFocused($focused)
		}
	}
}

/// The two-line row used for channels, groups, programmes, sources and recordings.
struct RowLabel: View {
	let line1: String
	var line2: String = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(line1).font(.body).frame(maxWidth: .infinity, alignment: .leading)
			if !line2.isEmpty { Text(line2).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
		}
		.multilineTextAlignment(.leading)
		.contentShape(Rectangle())
	}
}

/// A status line: shown, and spoken by the caller through announce().
struct StatusLine: View {
	let text: String
	var body: some View {
		if !text.isEmpty { Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
	}
}

/// A list to pick one entry from: audio tracks, subtitles, cast devices, recent channels.
/// The current one carries the Selected trait.
struct ChoiceSheet: View {
	let title: String
	let options: [String]
	var selected: Int? = nil
	let choose: (Int) -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			List(options.indices, id: \.self) { i in
				Button {
					dismiss()
					choose(i)
				} label: {
					HStack {
						Text(options[i])
						Spacer()
						if i == selected { Image(systemName: "checkmark").accessibilityHidden(true) }
					}
				}
				.accessibilityAddTraits(i == selected ? .isSelected : [])
			}
			.navigationTitle(title)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
			}
		}
	}
}

/// Details, account info and release notes: a heading and scrollable text.
struct InfoSheet: View {
	let info: InfoText
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			ScrollView {
				Text(info.text)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding()
					#if os(tvOS)
					.focusable()
					#endif
			}
			.navigationTitle(info.title)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) { Button(L("ok")) { dismiss() } }
			}
		}
	}
}

/// A labelled text field: visible label above, the same name for VoiceOver, an error under it.
struct LabeledField: View {
	let label: String
	@Binding var text: String
	var prompt: String = ""
	var secure = false
	var error: String? = nil
	#if !os(tvOS) && !os(macOS)
	var keyboard: UIKeyboardType = .default
	#endif

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label).font(.callout).accessibilityHidden(true)
			Group {
				if secure {
					SecureField(label, text: $text, prompt: Text(prompt))
						.textContentType(.password)
						.accessibilityLabel(label)
				} else {
					TextField(label, text: $text, prompt: Text(prompt))
						.accessibilityLabel(label)
				}
			}
			.textInputAutocapitalization(.never)
			.autocorrectionDisabled()
			#if !os(tvOS) && !os(macOS)
			.keyboardType(keyboard)
			#endif
			// The error sits right after the field, so VoiceOver reads it next; the form also
			// moves focus to the field and speaks the error when Save finds it.
			if let error {
				// Bold keeps system red above 3:1 (large-text contrast) in light and dark mode.
				Text(error).font(.callout.bold()).foregroundStyle(.red)
			}
		}
	}
}
