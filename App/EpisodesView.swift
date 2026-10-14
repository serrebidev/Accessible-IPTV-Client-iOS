import SwiftUI
import IPTVCore

/// A show's episodes, in season order.
struct EpisodesView: View {
	let key: String
	@EnvironmentObject private var model: AppModel
	@State private var all: [Channel] = []
	@State private var filter = ""
	@State private var status = ""
	@State private var title = ""
	@State private var loaded = false

	private var shown: [Channel] { filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) } }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			TextField(L("filter"), text: $filter, prompt: Text(L("filter")))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.accessibilityLabel(L("filter"))
			StatusLine(text: status)
			Text(P("episode_count", shown.count)).font(.headline).heading()
			List(shown) { ep in
				Button { model.open(ep) } label: { RowLabel(line1: ep.name) }
					.row(ep.name, actions: actions(ep))
			}
			.listStyle(.plain)
		}
		.padding(.horizontal)
		.navigationTitle(title)
		.task {
			guard !loaded else { return }
			loaded = true
			say(L("loading"))
			// A relaunched app has to load the series list again first.
			guard let show = await model.library.findChannel(key, section: Library.series) else { model.path.removeLast(); return }
			title = show.name
			do {
				all = try await model.library.episodes(show)
				say("")
			} catch {
				say(L("load_errors", error.localizedDescription))
			}
		}
	}

	private func say(_ s: String) { status = s; announce(s) }

	private func actions(_ ep: Channel) -> [RowAction] {
		var out: [RowAction] = []
		if let plot = ep.attrs["plot"], !plot.trimmingCharacters(in: .whitespaces).isEmpty {
			out.append(RowAction(L("programme_details")) { model.showInfo(ep.name, plot) })
		}
		out.append(RowAction(L("play_external")) { model.open(ep, external: true) })
		out.append(RowAction(L("download")) {
			model.recorder.download(ep.url, name: title, title: ep.name)
			say(L("downloading", ep.name))
		})
		return out
	}
}
