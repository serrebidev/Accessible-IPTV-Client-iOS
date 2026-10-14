import SwiftUI
import IPTVCore

/// What's on now, guide search across all channels, or one channel's guide with catch-up.
struct ProgrammesView: View {
	enum Mode: Equatable { case onNow, search, channel(String) }
	let mode: Mode

	private struct Item: Identifiable {
		let p: Programme
		let ch: Channel
		var id: String { "\(ch.key)|\(p.start)" }
	}

	@EnvironmentObject private var model: AppModel
	@State private var all: [Item] = []
	@State private var filter = ""
	@State private var status = ""
	@State private var title = ""
	@State private var searchTask: Task<Void, Never>?
	@State private var loaded = false
	@AccessibilityFocusState private var focus: String?

	private var oneChannel: Bool { if case .channel = mode { return true } else { return false } }
	private var library: Library { model.library }

	private var shown: [Item] {
		if mode == .search || filter.isEmpty { return all }
		return all.filter { $0.p.title.localizedCaseInsensitiveContains(filter) || $0.ch.name.localizedCaseInsensitiveContains(filter) }
	}

	var body: some View {
		ScrollViewReader { proxy in
			VStack(alignment: .leading, spacing: 8) {
				if !oneChannel {
					TextField(L(mode == .search ? "search" : "filter"), text: $filter, prompt: Text(L(mode == .search ? "search" : "filter")))
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.submitLabel(.search)
						.accessibilityLabel(L(mode == .search ? "search" : "filter"))
				}
				StatusLine(text: status)
				Text(P("programme_count", shown.count)).font(.headline).accessibilityAddTraits(.isHeader)
				List(shown) { item in row(item).id(item.id) }.listStyle(.plain)
			}
			.padding(.horizontal)
			.navigationTitle(title)
			.task {
				guard !loaded else { return }
				loaded = true
				await load(proxy)
			}
		}
		.onChange(of: filter) { _, q in
			guard mode == .search else { return }
			// Guide search queries the database as you type, debounced.
			searchTask?.cancel()
			searchTask = Task {
				try? await Task.sleep(nanoseconds: 400_000_000)
				guard !Task.isCancelled else { return }
				if !library.isLoaded(Library.live) { _ = await library.load(Library.live, force: false) }
				let q = q.trimmingCharacters(in: .whitespaces)
				let lib = library
				let found = q.count < 2 ? [] : await Task.detached { lib.epg.search(q, lib.channels) }.value
				all = found.map { Item(p: $0.0, ch: $0.1) }
				say(q.count >= 2 && all.isEmpty ? L("no_matches") : "")
			}
		}
	}

	private func say(_ s: String) {
		status = s
		announce(s)
	}

	private func load(_ proxy: ScrollViewProxy) async {
		switch mode {
		case .search:
			title = L("search_guide")
			return
		case .onNow:
			title = L("whats_on_now")
		case .channel:
			break
		}
		say(L("loading"))
		// A relaunched app has to load the channel list again first.
		if !library.isLoaded(Library.live) { _ = await library.load(Library.live, force: false) }
		var ch: Channel?
		if case .channel(let key) = mode {
			ch = library.channel(key)
			guard let c = ch else { model.path.removeLast(); return }
			title = L("guide_for", c.name)
		}
		let lib = library, days = model.prefs.epgDaysAhead
		let found: [(Programme, Channel)] = await Task.detached {
			if let c = ch {
				let now = nowMs()
				let back = Int64(c.hasCatchup ? max(1, c.catchupDays) : 0)
				return lib.epg.schedule(c, from: now - back * 86_400_000, to: now + Int64(days) * 86_400_000).map { ($0, c) }
			}
			return lib.epg.onNow(lib.channels)
		}.value
		all = found.map { Item(p: $0.0, ch: $0.1) }
		say(all.isEmpty ? (ch.map { L("no_guide_for", $0.name) } ?? L("no_guide")) : "")
		// Start at the programme on now, not at the top of the archive.
		if ch != nil, let i = all.firstIndex(where: { $0.p.stop > nowMs() }), i > 0 {
			proxy.scrollTo(all[i].id, anchor: .top)
			focus = all[i].id
		}
	}

	private func catchupState(_ p: Programme, _ ch: Channel, _ now: Int64) -> Bool {
		p.stop <= now && ch.hasCatchup && Catchup.withinWindow(ch, p.start)
	}

	private func row(_ item: Item) -> some View {
		let p = item.p, ch = item.ch, now = nowMs()
		let state: String
		if p.stop <= now { state = L(catchupState(p, ch, now) ? "catchup_available" : "ended") }
		else if p.start <= now { state = L("on_now") }
		else { state = Format.date(p.start) == Format.date(now) ? "" : Format.date(p.start) }
		let line2 = [oneChannel ? "" : ch.name, state].filter { !$0.isEmpty }.joined(separator: ", ")
		let speech = [Format.programme(p), oneChannel ? "" : ch.name, state].filter { !$0.isEmpty }.joined(separator: ", ")
		var actions: [RowAction] = []
		if !p.description.trimmingCharacters(in: .whitespaces).isEmpty {
			actions.append(RowAction(L("programme_details")) { model.showInfo(p.title, "\(Format.programme(p))\n\n\(p.description)") })
		}
		if p.stop > now { actions.append(RowAction(L("schedule_recording")) { schedule(p, ch) }) }
		if catchupState(p, ch, now) {
			actions.append(RowAction(L("download")) {
				withCatchup(p, ch) { url in
					model.recorder.download(url, name: ch.name, title: p.title, expectMs: p.stop - p.start)
					say(L("downloading", p.title))
				}
			})
		}
		if !oneChannel { actions.append(RowAction(L("channel_guide")) { model.path.append(.channelGuide(ch.key)) }) }
		return Button { open(p, ch) } label: { RowLabel(line1: Format.programme(p), line2: line2) }
			.row(speech, actions: actions)
			.accessibilityFocused($focus, equals: item.id)
	}

	private func open(_ p: Programme, _ ch: Channel) {
		if p.stop > nowMs() { model.open(ch); return }
		withCatchup(p, ch) { url in model.play(url, title: "\(ch.name): \(p.title)", key: ch.key, catchup: true) }
	}

	/// Builds the archive URL off the main thread (Stalker asks the portal) and hands it on.
	private func withCatchup(_ p: Programme, _ ch: Channel, then: @escaping (String) -> Void) {
		Task {
			if let url = await library.catchupUrl(ch, start: p.start, stop: p.stop) { then(url) } else { say(L("no_catchup")) }
		}
	}

	private func schedule(_ p: Programme, _ ch: Channel) {
		model.recorder.schedule(ch, title: p.title, start: p.start, end: p.stop)
		say(L("recording_scheduled", p.title, Format.dateTime(p.start)))
	}
}
