import SwiftUI
import IPTVCore

/// What's on now, guide search across all channels, or one channel's guide with catch-up.
struct ProgrammesView: View {
	enum Mode: Equatable { case onNow, search, channel(String) }
	let mode: Mode

	private struct Item: Identifiable {
		let p: Programme
		let ch: Channel
		/// The day this programme starts, worked out once: rows are built over and over.
		let day: String
		var id: String { "\(ch.key)|\(p.start)" }
		init(_ p: Programme, _ ch: Channel) { self.p = p; self.ch = ch; day = Format.date(p.start) }
	}

	@EnvironmentObject private var model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var all: [Item] = []
	@State private var displayed: [Item] = []
	@State private var filteredCount = 0
	@State private var filter = ""
	@State private var status = ""
	@State private var title = ""
	@State private var searchTask: Task<Void, Never>?
	@State private var loaded = false
	@State private var window = Self.windowSize
	@State private var lastSearch = ""
	@AccessibilityFocusState private var focus: String?

	/// How many rows the list is given at once; the rest are one More row away. SwiftUI
	/// builds a row for every entry it is handed, which froze the channel list at 93k rows.
	private static let windowSize = 2_000

	private var oneChannel: Bool { if case .channel = mode { return true } else { return false } }
	private var library: Library { model.library }

	private struct DayGroup: Identifiable {
		let day: String
		var items: [Item]
		var id: String { day }
	}

	/// Displayed items grouped under their day, in order, so VoiceOver heading
	/// navigation can jump a day at a time instead of swiping every programme.
	private var groups: [DayGroup] {
		var out: [DayGroup] = []
		for item in displayed {
			if out.last?.day == item.day { out[out.count - 1].items.append(item) } else { out.append(DayGroup(day: item.day, items: [item])) }
		}
		return out
	}

	var body: some View {
		ScrollViewReader { proxy in
			VStack(alignment: .leading, spacing: 8) {
				TextField(L(mode == .search ? "search" : "filter"), text: $filter, prompt: Text(L(mode == .search ? "search" : "filter")))
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.submitLabel(.search)
					.accessibilityLabel(L(mode == .search ? "search" : "filter"))
				StatusLine(text: status)
				Text(P("programme_count", filteredCount)).font(.headline).accessibilityAddTraits(.isHeader)
				if loaded && all.isEmpty && mode != .search {
					Button(L("import_guide")) { importGuide() }
				}
				List {
					ForEach(groups, id: \.day) { group in
						Section {
							ForEach(group.items) { item in row(item).id(item.id) }
						} header: {
							Text(group.day).accessibilityAddTraits(.isHeader)
						}
					}
					if displayed.count < filteredCount {
						Section {
							Button { window += Self.windowSize; refreshShown() } label: {
								RowLabel(line1: L("more"), line2: P("programme_count", filteredCount - displayed.count))
							}
							.row("\(L("more")), \(P("programme_count", filteredCount - displayed.count))", actions: [])
						}
					}
				}
				.listStyle(.plain)
				.accessibilityLabel(L("guide_heading"))
			}
			.padding(.horizontal)
			.navigationTitle(title)
			.task {
				guard !loaded else { return }
				loaded = true
				await load(proxy, moveFocus: true)
			}
			.onChange(of: model.revision) { _, _ in
				// A guide import that finishes behind this screen replaces its data.
				guard loaded, mode != .search else { return }
				Task { await load(proxy, moveFocus: false) }
			}
		}
		.onChange(of: filter) { _, q in
			if mode == .search { queueSearch(q) } else { window = Self.windowSize; refreshShown() }
		}
	}

	/// Rebuilds what the list shows from [all] and the filter. Runs when data or the
	/// filter changes, never per redraw.
	private func refreshShown() {
		let q = filter.trimmingCharacters(in: .whitespaces)
		let kept = mode == .search || q.isEmpty ? all : all.filter {
			$0.p.title.localizedCaseInsensitiveContains(q) || $0.ch.name.localizedCaseInsensitiveContains(q)
		}
		filteredCount = kept.count
		displayed = Array(kept.prefix(window))
	}

	private func queueSearch(_ raw: String) {
		searchTask?.cancel()
		searchTask = Task {
			try? await Task.sleep(nanoseconds: 400_000_000)
			guard !Task.isCancelled else { return }
			let q = raw.trimmingCharacters(in: .whitespaces)
			guard q.count >= 2 else {
				all = []; lastSearch = ""; window = Self.windowSize; refreshShown()
				say(q.isEmpty ? "" : L("guide_search_hint"))
				return
			}
			if !library.isLoaded(Library.live) { _ = await library.load(Library.live, force: false) }
			// Typing one more character only narrows the last answer: reuse it instead
			// of scanning the whole guide database again, unless it was cut at the limit.
			let found: [Item]
			if !lastSearch.isEmpty, q.hasPrefix(lastSearch), all.count < 500 {
				found = all.filter {
					$0.p.title.localizedCaseInsensitiveContains(q) || $0.p.description.localizedCaseInsensitiveContains(q)
				}
			} else {
				let lib = library
				found = await Task.detached { lib.epg.search(q, lib.channels) }.value.map { Item($0.0, $0.1) }
			}
			guard !Task.isCancelled else { return }
			lastSearch = q
			all = found
			window = Self.windowSize
			refreshShown()
			if found.count >= 500 { say(L("results_limited")) }
			else if found.isEmpty { say(L("no_matches")) }
			else { say(""); announce(P("programme_count", found.count)) }
		}
	}

	private func say(_ s: String) {
		status = s
		announce(s)
	}

	private func importGuide() {
		say(L("importing_guide"))
		Task {
			do {
				_ = try await library.importGuide()
				model.refresh()
				say(L("guide_imported"))
			} catch { say(L("guide_failed", error.localizedDescription)) }
		}
	}

	private func load(_ proxy: ScrollViewProxy, moveFocus: Bool) async {
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
			guard let c = ch else { dismiss(); return }
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
		all = found.map { Item($0.0, $0.1) }
		refreshShown()
		if all.isEmpty {
			say(ch.map { L("no_guide_for", $0.name) } ?? L("no_guide"))
		} else {
			say("")
			announce(P("programme_count", all.count))
		}
		// Start at the programme on now, not at the top of the archive.
		if moveFocus, ch != nil, let i = displayed.firstIndex(where: { $0.p.stop > nowMs() }), i > 0 {
			proxy.scrollTo(displayed[i].id, anchor: .top)
			focus = displayed[i].id
		}
	}

	private func catchupState(_ p: Programme, _ ch: Channel, _ now: Int64) -> Bool {
		p.stop <= now && ch.hasCatchup && Catchup.withinWindow(ch, p.start)
	}

	private func row(_ item: Item) -> some View {
		let p = item.p, ch = item.ch, now = nowMs()
		var state: [String] = []
		if item.day != Format.date(now) { state.append(item.day) }
		if p.stop <= now { state.append(L(catchupState(p, ch, now) ? "catchup_available" : "ended")) }
		else if p.start <= now { state.append(L("on_now")) }
		let line2 = [oneChannel ? "" : ch.name, state.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ", ")
		let speech = [Format.programme(p), oneChannel ? "" : ch.name, state.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ", ")
		var actions: [RowAction] = []
		if !p.description.trimmingCharacters(in: .whitespaces).isEmpty {
			actions.append(RowAction(L("programme_details")) { details(p) })
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
		if !oneChannel { actions.append(RowAction(L("channel_guide")) { model.navigate(.channelGuide(ch.key)) }) }
		return Button { open(p, ch) } label: { RowLabel(line1: Format.programme(p), line2: line2) }
			.row(speech, actions: actions)
			.accessibilityFocused($focus, equals: item.id)
	}

	private func details(_ p: Programme) {
		model.showInfo(p.title, "\(Format.date(p.start)), \(Format.programme(p))\n\n\(p.description)")
	}

	private func open(_ p: Programme, _ ch: Channel) {
		// A programme that has not started yet shows its details; recording it is a row action.
		if p.start > nowMs() { details(p); return }
		if p.stop > nowMs() { model.open(ch); return }
		withCatchup(p, ch) { url in
			model.play(url, title: "\(ch.name): \(p.title)", key: ch.key, catchup: true, channel: ch,
				archiveStart: p.start, archiveStop: p.stop)
		}
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

/// Pick a channel, then read its guide: the Guide section's way in, without
/// hunting through Browse categories first.
struct GuideChannelPicker: View {
	@EnvironmentObject private var model: AppModel
	@State private var query = ""
	@State private var results: [Channel] = []
	@State private var total = 0
	@State private var window = 2_000
	@State private var searchTask: Task<Void, Never>?

	private var library: Library { model.library }

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			TextField(L("search"), text: $query, prompt: Text(L("search")))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.search)
				.accessibilityLabel(L("search"))
			Text(P("channel_count", total)).font(.headline).accessibilityAddTraits(.isHeader)
			List {
				ForEach(Array(results.prefix(window))) { ch in
					let line = nowLine(ch)
					Button { model.navigate(.channelGuide(ch.key)) } label: {
						RowLabel(line1: ch.name, line2: line)
					}
					.row(Format.sentences([ch.name, line]), actions: [])
				}
				if window < results.count {
					Button { window += 2_000 } label: {
						RowLabel(line1: L("more"), line2: P("channel_count", results.count - window))
					}
					.row("\(L("more")), \(P("channel_count", results.count - window))", actions: [])
				}
			}
			.listStyle(.plain)
			.accessibilityLabel(L("channels"))
		}
		.padding(.horizontal)
		.navigationTitle(L("channel_guide"))
		.task { await refresh("") }
		.onChange(of: query) { _, q in
			searchTask?.cancel()
			searchTask = Task {
				try? await Task.sleep(nanoseconds: 300_000_000)
				guard !Task.isCancelled else { return }
				await refresh(q)
			}
		}
	}

	private func nowLine(_ ch: Channel) -> String {
		library.epg.nowNext(ch).now.map { L("until", $0.title, Format.time($0.stop)) } ?? ""
	}

	private func refresh(_ raw: String) async {
		if !library.isLoaded(Library.live) { _ = await library.load(Library.live, force: false) }
		let q = raw.trimmingCharacters(in: .whitespaces)
		let lib = library
		let found = await Task.detached { q.isEmpty ? lib.channels : lib.search(Library.live, q) }.value
		results = found
		total = found.count
		window = 2_000
	}
}
