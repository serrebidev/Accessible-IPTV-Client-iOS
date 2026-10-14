import SwiftUI
import IPTVCore

/// Recordings in progress first (each with Stop), then scheduled ones, then saved files.
struct RecordingsView: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject private var recorder = AppModel.shared.recorder
	@State private var saved: [RecorderCenter.Saved] = []
	@State private var status = ""
	@State private var cancelling: Recording.Scheduled?
	@State private var deleting: RecorderCenter.Saved?
	/// After a confirmation closes, VoiceOver goes back to the list heading.
	@AccessibilityFocusState private var headingFocus: Bool

	private var now: [RecorderCenter.Active] { recorder.active.values.sorted { $0.started < $1.started } }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Button(L("stop_all_recordings")) {
				recorder.stopAll()
				say(L("recordings_stopped"))
			}
			.buttonStyle(.bordered)
			StatusLine(text: status)
			Text(L("recordings_heading", now.count, recorder.scheduled.count, saved.count)).font(.headline).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocus)
			List {
				ForEach(now) { a in
					let line2 = a.end > 0 ? L("recording_until", Format.time(a.end)) : L("recording_now")
					let stop = { recorder.stop(a.key); say(L("recording_stopped", a.label)) }
					Button(action: stop) { RowLabel(line1: a.label, line2: line2) }
						.row("\(a.label), \(line2)", actions: [RowAction(L("stop_recording"), stop)])
				}
				ForEach(recorder.scheduled) { s in
					let line1 = [s.title, s.name].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
					let line2 = L("scheduled_for", Format.dateTime(s.start), Format.time(s.end))
					Button { cancelling = s } label: { RowLabel(line1: line1, line2: line2) }
						.row("\(line1), \(line2)", actions: [RowAction(L("cancel_recording")) { cancelling = s }])
				}
				ForEach(saved) { f in
					let line2 = Format.dateTime(f.added)
					Button { model.play(f.url.absoluteString, title: f.name, key: "", catchup: true) } label: { RowLabel(line1: f.name, line2: line2) }
						.row("\(f.name), \(line2)", actions: actions(f))
				}
			}
			.listStyle(.plain)
		}
		.padding(.horizontal)
		.navigationTitle(L("recordings"))
		.onAppear { saved = recorder.saved() }
		.onChange(of: recorder.active.count) { _, _ in saved = recorder.saved() }
		.alert(L("cancel_recording"), isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), presenting: cancelling) { s in
			Button(L("cancel_recording"), role: .destructive) {
				recorder.cancel(s.id)
				say(L("recording_cancelled"))
				headingFocus = true
			}
			Button(L("keep"), role: .cancel) { headingFocus = true }
		} message: { s in
			Text(L("cancel_recording_q", s.title.isEmpty ? s.name : s.title))
		}
		.alert(L("delete"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
			Button(L("delete"), role: .destructive) {
				recorder.delete(f)
				saved = recorder.saved()
				say(L("recording_deleted", f.name))
				headingFocus = true
			}
			Button(L("cancel"), role: .cancel) { headingFocus = true }
		} message: { f in
			Text(L("delete_recording_q", f.name))
		}
	}

	private func actions(_ f: RecorderCenter.Saved) -> [RowAction] {
		var out = [RowAction(L("delete")) { deleting = f }]
		#if os(iOS) || os(visionOS)
		out.append(RowAction(L("play_external")) { ExternalPlayers.share(f.url) })
		#endif
		return out
	}

	private func say(_ s: String) { status = s; announce(s) }
}
