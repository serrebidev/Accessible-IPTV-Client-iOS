import SwiftUI
import UIKit
import IPTVCore

private struct GroupItem: Identifiable, Equatable {
	let name: String
	let count: Int
	var id: String { name }
}

/// Search, sections, the button bar, groups and the channel list. Port of MainActivity.
struct MainView: View {
	@EnvironmentObject private var model: AppModel
	@ObservedObject private var sharePlay = SharePlayCenter.shared
	@Environment(\.horizontalSizeClass) private var sizeClass
	@Environment(\.openURL) private var openURL

	@State private var query = ""
	@State private var section = Library.live
	@State private var group = Library.all
	@State private var groupSelected = false
	@State private var groups: [GroupItem] = []
	@State private var channels: [Channel] = []
	@State private var favs: Set<String> = []
	@State private var heading = ""
	@State private var details = ""
	/// Bumped whenever what the channel rows show changes (list, favourites, guide, recordings).
	@State private var listVersion = 0
	/// How much of the category the list holds, and which category that was.
	@State private var shown = 0
	@State private var shownFor = ""
	@State private var searchTask: Task<Void, Never>?
	@State private var showRecent = false
	@State private var showGroups = false
	@State private var showNumber = false
	@State private var update: Updater.Release?
	@State private var digits = ""
	@State private var digitTask: Task<Void, Never>?
	@State private var started = false
	@AccessibilityFocusState private var headingFocused: Bool
	@AccessibilityFocusState private var voFocus: String?
	@FocusState private var focusedKey: String?
	#if canImport(Speech) && !os(tvOS)
	@StateObject private var voice = VoiceSearch()
	#endif

	private var library: Library { model.library }
	private var prefs: Prefs { model.prefs }

	var body: some View {
		#if os(iOS)
		TabView(selection: $model.selectedTab) {
			NavigationStack(path: $model.path) {
				content
					.navigationTitle(L("browse"))
					.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
					.navigationDestination(for: Route.self) { route in
						destination(route).safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
					}
			}
			.tabItem { Label(L("browse"), systemImage: "square.grid.2x2") }.tag(0)
			NavigationStack(path: $model.guidePath) {
				List {
					NavigationLink(value: Route.onNow) { Label(L("whats_on_now"), systemImage: "tv") }
					NavigationLink(value: Route.guideSearch) { Label(L("search_guide"), systemImage: "magnifyingglass") }
				}
				.navigationTitle(L("guide_heading"))
				.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
				.navigationDestination(for: Route.self) { route in
					destination(route).safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
				}
			}
			.tabItem { Label(L("guide_heading"), systemImage: "list.bullet.rectangle") }.tag(1)
			NavigationStack {
				RecordingsView()
					.navigationTitle(L("recordings"))
					.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
			}
			.tabItem { Label(L("recordings"), systemImage: "record.circle") }.tag(2)
			NavigationStack {
				SettingsView()
					.navigationTitle(L("settings"))
					.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
			}
			.tabItem { Label(L("settings"), systemImage: "gearshape") }.tag(3)
		}
		#else
		NavigationStack(path: $model.path) {
			content
				.navigationTitle(L("app_name"))
				.navigationDestination(for: Route.self) { destination($0) }
				.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
		}
		#endif
	}

	@ViewBuilder private var miniPlayer: some View {
		if let player = model.player, !model.playerPresented { MiniPlayer(c: player) }
		if sharePlay.isActive && model.player == nil { SharePlaySessionControls().padding() }
	}

	@ViewBuilder private func destination(_ r: Route) -> some View {
		switch r {
		case .category(let name):
			channelColumn
				.navigationTitle(groupLabel(name))
				#if os(iOS)
				.navigationBarTitleDisplayMode(.inline)
				.searchable(text: $query, prompt: L("search"))
				#endif
		case .sources: SourcesView()
		case .onNow: ProgrammesView(mode: .onNow)
		case .guideSearch: ProgrammesView(mode: .search)
		case .recordings: RecordingsView()
		case .settings: SettingsView()
		case .help: HelpView()
		case .channelGuide(let key): ProgrammesView(mode: .channel(key))
		case .episodes(let key): EpisodesView(key: key)
		}
	}

	private var content: some View {
		let _ = SwitchTiming.body()
		return VStack(alignment: .leading, spacing: 8) {
			#if !os(iOS)
			searchBar
			#endif
			Picker(L("section"), selection: $section) {
				Text(L("live_tv")).tag(Library.live)
				Text(L("movies")).tag(Library.movies)
				Text(L("series")).tag(Library.series)
			}
			.pickerStyle(.segmented)
			.accessibilityElement(children: .contain)
			.accessibilityLabel(L("section"))
			.padding(.horizontal)
			#if !os(iOS)
			buttonBar
			#endif
			StatusLine(text: model.status).padding(.horizontal)
			lists
		}
		#if os(iOS)
		.searchable(text: $query, prompt: L("search"))
		.textInputAutocapitalization(.never)
		.autocorrectionDisabled()
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				Button { model.path.append(.sources) } label: { Label(L("playlists_and_guides"), systemImage: "plus") }
			}
			ToolbarItemGroup(placement: .topBarTrailing) {
				#if canImport(Speech)
				Button { voice.toggle { query = $0 } status: { model.setStatus($0) } } label: {
					Label(L("voice_search"), systemImage: "mic")
				}
				#endif
				moreMenu
			}
		}
		#else
		.padding(.horizontal)
		#endif
		.task {
			guard !started else { return }
			started = true
			load(force: false)
			// Once a day, quietly: only speaks up when there is something to install.
			if nowMs() - prefs.lastUpdateCheck > 86_400_000 { checkUpdates(quiet: true) }
		}
		.onAppear {
			if model.sourcesChanged {
				model.sourcesChanged = false
				load(force: false, all: true)
			}
		}
		.onReceive(model.recorder.$active) { _ in listVersion += 1 }
		.onChange(of: model.revision) { _, _ in
			favs = prefs.favorites
			listVersion += 1
			Task { await refreshGroupCounts(); await showChannels() }
		}
		.onChange(of: section) { _, s in selectSection(s) }
		.onChange(of: query) { _, _ in
			searchTask?.cancel()
			// Debounced so typing stays responsive and results are not re-announced per key.
			searchTask = Task {
				try? await Task.sleep(nanoseconds: 300_000_000)
				if !Task.isCancelled { await showChannels() }
			}
		}
		.onChange(of: focusedKey) { _, k in if let k { details = detailsText(k) } }
		.onChange(of: voFocus) { _, k in if let k { details = detailsText(k) } }
		.onKeyPress(characters: .decimalDigits, phases: .down) { press in
			typeDigit(press.characters)
			return .handled
		}
		.sheet(isPresented: $showRecent) {
			let recent = recentChannels()
			ChoiceSheet(title: L("recently_watched"), options: recent.map(\.name)) { model.open(recent[$0]) }
		}
		.sheet(isPresented: $showGroups) {
			// The rows are built by the List as they come into view, so a provider with hundreds
			// of categories costs the same as one with a handful. [list] is this presentation's
			// copy, so a refresh behind the sheet cannot move the row out from under the tap.
			let list = groups
			ChoiceSheet(title: L("groups"), options: list.map { "\(groupLabel($0.name)), \($0.count)" },
				selected: list.firstIndex { $0.name == group }) { i in
				selectGroup(list[i].name)
			}
		}
		.sheet(isPresented: $showNumber) { NumberSheet() }
		.alert(update.map { L("update_available", $0.version) } ?? "", isPresented: Binding(get: { update != nil }, set: { if !$0 { update = nil } })) {
			#if os(iOS)
			Button(L("install")) { if let u = update { install(u) }; headingFocused = true }
			Button(L("later"), role: .cancel) { headingFocused = true }
			#else
			Button(L("ok"), role: .cancel) { headingFocused = true }
			#endif
		} message: {
			Text(String((update?.notes ?? "").prefix(1500)))
		}
	}

	// MARK: search

	private var searchBar: some View {
		HStack {
			TextField(L("search"), text: $query, prompt: Text(L("search")))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.submitLabel(.search)
				.onSubmit {
					// The keyboard's Search key: search now and move to the results.
					searchTask?.cancel()
					Task {
						await showChannels()
						headingFocused = true
					}
				}
				.accessibilityLabel(L("search"))
			if !query.isEmpty {
				// Like Back or Escape clearing the search on Android and the desktop.
				Button(L("clear")) { query = "" }
			}
			#if canImport(Speech) && !os(tvOS)
			Button(L("voice_search")) {
				voice.toggle { heard in
					query = heard
				} status: { model.setStatus($0) }
			}
			#endif
		}
		#if os(tvOS)
		.onExitCommand { if !query.isEmpty { query = "" } }
		#endif
	}

	// MARK: buttons

	private var buttonBar: some View {
		// Real buttons, not an overflow menu: reachable by swipe, keyboard and remote alike.
		ScrollView(.horizontal) {
			HStack {
				Button(L("playlists_and_guides")) { model.path.append(.sources) }
				Button(L("whats_on_now")) { model.path.append(.onNow) }
				Button(L("search_guide")) { model.path.append(.guideSearch) }
				Button(L("recordings")) { model.path.append(.recordings) }
				moreMenu
			}
			.buttonStyle(.bordered)
		}
	}

	private var moreMenu: some View {
		Menu {
			Button(L("previous_channel")) { playPrevious() }
			Button(L("recently_watched")) {
				if recentChannels().isEmpty { model.setStatus(L("no_recent")) } else { showRecent = true }
			}
			Button(L("go_to_number")) { showNumber = true }
			Button(L("refresh_playlists")) { load(force: true, all: true) }
			Button(L("import_guide")) { importGuide(manual: true) }
			Button(L("account_info")) { showAccountInfo() }
			#if !os(iOS)
			Button(L("settings")) { model.path.append(.settings) }
			#endif
			Button(L("check_updates")) { checkUpdates(quiet: false) }
			Button(L("help")) { model.path.append(.help) }
		} label: {
			Label(L("more"), systemImage: "ellipsis.circle")
		}
	}

	// MARK: lists

	private var wide: Bool {
		#if os(tvOS) || os(visionOS)
		return true
		#else
		return sizeClass == .regular
		#endif
	}

	@ViewBuilder private var lists: some View {
		if wide {
			HStack(alignment: .top, spacing: 16) {
				VStack(alignment: .leading) {
					Text(L("groups")).font(.headline).accessibilityAddTraits(.isHeader)
					List(groups) { g in groupRow(g) }.listStyle(.plain)
				}
				.frame(maxWidth: 360)
				if groupSelected || !query.isEmpty { channelColumn }
			}
		} else {
			#if os(iOS)
			if !query.trimmingCharacters(in: .whitespaces).isEmpty {
				channelColumn
			} else {
				List {
					Section {
						ForEach(groups) { g in
							Button { selectGroup(g.name) } label: {
								HStack {
									RowLabel(line1: groupLabel(g.name), line2: countText(g.count))
									Image(systemName: "chevron.forward").foregroundStyle(.secondary).accessibilityHidden(true)
								}
							}
							.row("\(groupLabel(g.name)), \(countText(g.count))", actions: [])
							.accessibilityLabel("\(groupLabel(g.name)), \(countText(g.count))")
						}
					} header: { Text(L("groups")).accessibilityAddTraits(.isHeader) }
					if prefs.sources.isEmpty {
						Button(L("playlists_and_guides")) { model.path.append(.sources) }
					}
				}
				.listStyle(.insetGrouped)
				.accessibilityLabel(L("groups"))
			}
			#else
			VStack(alignment: .leading) {
				// A phone has no room for two lists side by side: one button opens the categories.
				// A menu would build an entry for every one of them on every redraw, and providers
				// have hundreds; the sheet is a List, so only the rows in view exist.
				Button("\(L("groups")), \(groupLabel(group)), \(groupCount)") { showGroups = true }
					.buttonStyle(.bordered)
				channelColumn
			}
			#endif
		}
	}

	private var groupCount: Int { groups.first { $0.name == group }?.count ?? 0 }

	/// How many rows a list is given at once. SwiftUI builds a row for every entry it is handed,
	/// not just the ones on screen: one category of 93,816 channels took 5.8 seconds to build, and
	/// the screen was frozen for it. The rest of the category is one "More" row away.
	private static let window = 2_000

	/// The set of rows on show: a new category, a new section, or the first keystroke of a search.
	/// The channel list is keyed by this, so choosing a category builds the rows in view instead of
	/// asking SwiftUI to work out the difference from the category before it, which costs what the
	/// list costs: seconds on an account with tens of thousands of channels.
	private var listID: String {
		let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
		return "\(section)|\(searching ? "" : group)|\(searching ? "search" : "browse")"
	}

	private func groupRow(_ g: GroupItem) -> some View {
		Button { selectGroup(g.name) } label: { RowLabel(line1: groupLabel(g.name), line2: String(g.count)) }
			.row("\(groupLabel(g.name)), \(g.count)", actions: [])
			.accessibilityAddTraits(groupSelected && g.name == group ? .isSelected : [])
	}

	private var channelColumn: some View {
		VStack(alignment: .leading) {
			Text(heading).font(.headline).accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
			ChannelRows(channels: shownRows, favs: favs, showGroup: !query.isEmpty, version: listVersion, label: sectionName(),
				moreLine: channels.count > shown ? countText(channels.count - shown) : "", onMore: showMore,
				focusedKey: $focusedKey, voFocus: $voFocus) { channelActions($0, fav: $1) }
				.equatable()
				.id(listID)
			if !details.isEmpty {
				Text(details).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}

	/// The rows the list is given: all of them up to [window], else the head of the category.
	private var shownRows: [Channel] { shown >= channels.count ? channels : Array(channels.prefix(max(0, shown))) }

	/// The next window: twice the last, so a category of 50,000 is in reach in a few presses.
	private func showMore() {
		guard shown < channels.count else { return }
		let next = min(channels.count, max(shown * 2, shown + Self.window))
		let firstNew = channels[shown].key
		shown = next
		listVersion += 1
		// VoiceOver moves to the first row that was not there before.
		Task {
			try? await Task.sleep(nanoseconds: 300_000_000)
			voFocus = firstNew
		}
	}

	private func channelActions(_ ch: Channel, fav: Bool) -> [RowAction] {
		var out: [RowAction] = []
		if ch.kind != Channel.kindSeries { out.append(RowAction(L("play_external")) { model.open(ch, external: true) }) }
		out.append(RowAction(L(fav ? "remove_favorite" : "add_favorite")) {
			let now = prefs.toggleFavorite(ch.key)
			model.setStatus(L(now ? "added_favorite" : "removed_favorite", ch.name))
			favs = prefs.favorites
			listVersion += 1
			Task {
				await refreshGroupCounts()
				if group == Library.favorites { await showChannels() }
			}
		})
		out.append(RowAction(L("programme_details")) { model.showInfo(ch.name, detailsText(ch.key)) })
		if ch.isLive {
			out.append(RowAction(L(ch.hasCatchup ? "guide_and_catchup" : "channel_guide")) { model.path.append(.channelGuide(ch.key)) })
			if model.recorder.isRecording(ch.key) {
				out.append(RowAction(L("stop_recording_channel")) {
					model.recorder.stop(ch.key)
					model.setStatus(L("recording_stopped", ch.name))
				})
			} else {
				out.append(RowAction(L("record_now")) {
					model.recorder.start(ch, title: library.epg.nowNext(ch).now?.title ?? "")
					model.setStatus(L("recording_channel", ch.name))
				})
			}
		} else if ch.kind == Channel.kindMovie || ch.kind == Channel.kindEpisode {
			out.append(RowAction(L("download")) {
				model.recorder.download(ch.url, name: ch.name, title: "")
				model.setStatus(L("downloading", ch.name))
			})
		}
		return out
	}

	private func detailsText(_ key: String) -> String {
		guard let ch = channels.first(where: { $0.key == key }) ?? library.channel(key) else { return "" }
		var lines: [String] = []
		if ch.isLive {
			let nn = library.epg.nowNext(ch)
			if nn.isEmpty { lines.append(L("no_guide_for", ch.name)) }
			if let n = nn.now {
				lines.append(L("now_programme", Format.programme(n)))
				if !n.description.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(n.description) }
			}
			if let n = nn.next { lines.append(L("next_programme", Format.programme(n))) }
		} else {
			lines.append(ch.group)
			if let plot = ch.attrs["plot"], !plot.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(plot) }
		}
		if prefs.showStreamUrl && ch.kind != Channel.kindSeries { lines.append(L("stream_url_is", ch.url)) }
		return lines.joined(separator: "\n")
	}

	private func groupLabel(_ name: String) -> String {
		switch name {
		case Library.all: return L("all_in_section")
		case Library.favorites: return L("favorites")
		default: return name
		}
	}

	private func countText(_ n: Int) -> String {
		P(section == Library.movies ? "movie_count" : section == Library.series ? "series_count" : "channel_count", n)
	}

	private func sectionName() -> String {
		L(section == Library.movies ? "movies" : section == Library.series ? "series" : "channels")
	}

	// MARK: loading

	private func load(force: Bool, all: Bool = false) {
		if prefs.sources.isEmpty {
			model.setStatus(L("no_sources"))
			groups = []
			channels = []
			// The rows compare by this, not by [channels]: without it the deleted list stays on screen.
			listVersion += 1
			heading = ""
			return
		}
		SwitchTiming.begin(sectionName())
		model.setStatus(L(force ? "refreshing" : "loading"))
		let current = section
		Task {
			let t0 = nowMs()
			// Live always loads (the guide needs it); the other sections only once they are opened.
			let sections = all ? Library.sections.filter { $0 == Library.live || $0 == current || library.isLoaded($0) } : [current]
			var errors: [String] = []
			for s in sections { errors += await library.load(s, force: force) }
			#if os(iOS)
			IPTVShortcuts.updateAppShortcutParameters()
			#endif
			favs = prefs.favorites
			await refreshGroupCounts()
			await showChannels()
			SwitchTiming.before(nowMs() - t0)
			model.setStatus(errors.isEmpty ? countText(library.list(section).count) : L("load_errors", errors.joined(separator: "; ")))
			// Guide older than a day, or built for a different channel list: fetch it now.
			if section == Library.live && library.guideStale() { importGuide() }
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			SwitchTiming.report()
		}
	}

	private func selectSection(_ s: String) {
		group = Library.all
		groupSelected = false
		if library.isLoaded(s) {
			Task { await refreshGroupCounts(); await showChannels() }
			model.status = ""
		} else {
			load(force: false)
		}
	}

	/// Groups and their counts, counted off the main thread, and the chosen group reset to "All"
	/// when the section does not have it. The caller then loads the list.
	private func refreshGroupCounts() async {
		let lib = library, s = section
		// Counting every entry (250,000 for movies) used to happen on the main thread here, which
		// is what stalled the screen after a load or a section switch.
		let items = await Task.detached { lib.groupSummary(s).map { GroupItem(name: $0.name, count: $0.count) } }.value
		guard s == section else { return }
		groups = items
		if !items.contains(where: { $0.name == group }) {
			group = Library.all
			await showChannels()
		}
	}

	private func selectGroup(_ name: String) {
		SwitchTiming.begin(groupLabel(name))
		group = name
		groupSelected = true
		#if os(iOS)
		if !wide { model.path.append(.category(name)) }
		#endif
		if section == Library.live { prefs.lastGroup = name }
		Task {
			let t0 = nowMs()
			await showChannels()
			SwitchTiming.before(nowMs() - t0)
			// Move VoiceOver to the list heading so the result is heard straight away.
			headingFocused = true
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			SwitchTiming.report()
		}
	}

	private func showChannels() async {
		let q = query.trimmingCharacters(in: .whitespaces)
		guard groupSelected || !q.isEmpty else {
			channels = []
			shown = 0
			shownFor = ""
			heading = ""
			listVersion += 1
			return
		}
		let lib = library, s = section, g = group
		let list = await Task.detached(priority: .userInitiated) {
			// Search covers every group in the section; otherwise show the chosen group.
			q.isEmpty ? lib.channelsIn(s, g) : lib.search(s, q)
		}.value
		guard s == section, g == group, q == query.trimmingCharacters(in: .whitespaces) else { return }
		channels = list
		// A new category starts at the head of it; the same one keeps what was already shown.
		if shownFor != listID { shownFor = listID; shown = Self.window }
		shown = min(shown, list.count)
		listVersion += 1
		heading = q.isEmpty ? L("list_heading", groupLabel(group), list.count) : P("result_count", list.count)
	}

	/// Background guide loads are silent; only a failure, or a refresh the user asked for, is spoken.
	private func importGuide(manual: Bool = false) {
		if manual { model.setStatus(L("importing_guide")) }
		Task {
			do {
				_ = try await library.importGuide()
				model.refresh()
				if manual { model.setStatus(L("guide_imported")) }
			} catch {
				model.setStatus(L("guide_failed", error.localizedDescription))
			}
		}
	}

	// MARK: more

	/// Recent holds live keys only.
	private func recentChannels() -> [Channel] {
		var live: [String: Channel] = [:]
		for c in library.channels { live[c.key] = c }
		return prefs.recent.compactMap { live[$0] }
	}

	/// Desktop "Previous Channel": the live channel watched before the last one.
	private func playPrevious() {
		// Index the saved keys, not the found channels: a dropped newest key would shift "previous" one back.
		let recent = prefs.recent
		guard recent.count > 1, let prev = library.channels.first(where: { $0.key == recent[1] }) else {
			model.setStatus(L("no_previous"))
			return
		}
		model.open(prev)
	}

	/// Number keys on a keyboard jump to a channel, like a TV: typed digits wait 1.5 s for more.
	private func typeDigit(_ d: String) {
		guard digits.count < 6 else { return }
		digits += d
		model.setStatus(L("channel_typed", digits))
		digitTask?.cancel()
		digitTask = Task {
			try? await Task.sleep(nanoseconds: 1_500_000_000)
			guard !Task.isCancelled else { return }
			let n = digits
			digits = ""
			if let ch = Channel.byNumber(library.channels, n) { model.open(ch) } else { model.setStatus(L("number_not_found", n)) }
		}
	}

	private func checkUpdates(quiet: Bool) {
		prefs.lastUpdateCheck = nowMs()
		if !quiet { model.setStatus(L("checking_updates")) }
		Task {
			do {
				if let r = try await Updater.check(current: AppModel.version) { update = r }
				else if !quiet { model.setStatus(L("up_to_date")) }
			} catch {
				if !quiet { model.setStatus(L("update_failed", error.localizedDescription)) }
			}
		}
	}

	/// AltStore installs the update from the source this app came from; without it, the release page.
	private func install(_ r: Updater.Release) {
		#if os(iOS)
		let source = Updater.altSource.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Updater.altSource
		for scheme in ["altstore", "sidestore"] {
			if let u = URL(string: "\(scheme)://source?url=\(source)"), UIApplication.shared.canOpenURL(u) {
				UIApplication.shared.open(u)
				return
			}
		}
		if let page = URL(string: r.page) { openURL(page) }
		#endif
	}

	private func showAccountInfo() {
		let sources = prefs.sources.filter { $0.isXtream || $0.isStalker || Library.xtreamBehind($0) != nil }
		if sources.isEmpty { model.showInfo(L("account_info"), L("account_info_none")); return }
		model.setStatus(L("loading"))
		Task {
			var parts: [String] = []
			for src in sources {
				let lines: String
				do { lines = try await library.accountInfo(src).map { "\($0.0): \($0.1)" }.joined(separator: "\n") }
				catch { lines = L("account_info_failed", error.localizedDescription) }
				parts.append("\(src.name)\n\(lines)")
			}
			model.status = ""
			model.showInfo(L("account_info"), parts.joined(separator: "\n\n"))
		}
	}
}

/// Desktop "Go to Channel Number": the provider's number, else the nth live channel.
private struct NumberSheet: View {
	@EnvironmentObject private var model: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var number = ""
	@State private var error: String?
	@AccessibilityFocusState private var fieldFocused: Bool

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					#if os(tvOS)
					LabeledField(label: L("channel_number"), text: $number, error: error).accessibilityFocused($fieldFocused)
					#else
					LabeledField(label: L("channel_number"), text: $number, error: error, keyboard: .numberPad).accessibilityFocused($fieldFocused)
					#endif
					HStack {
						Button(L("play")) { go() }.buttonStyle(.borderedProminent)
						Button(L("cancel")) { dismiss() }.buttonStyle(.bordered)
					}
				}
				.padding()
			}
			.navigationTitle(L("go_to_number"))
		}
	}

	private func go() {
		if let ch = Channel.byNumber(model.library.channels, number) {
			dismiss()
			model.open(ch)
		} else {
			// Error on the field, and VoiceOver is moved there to hear it.
			let e = L("number_not_found", number.trimmingCharacters(in: .whitespaces))
			error = e
			fieldFocused = true
			announce(e)
		}
	}
}

/// The channel list on its own, compared by [version] only: the main screen's body re-runs on
/// every status-line change, and re-diffing a 50,000-row List each time burned CPU.
private struct ChannelRows: View, Equatable {
	let channels: [Channel]
	let favs: Set<String>
	/// While searching, results come from every group: say which when there is no guide.
	let showGroup: Bool
	let version: Int
	let label: String
	/// The count line for the "More" row: empty when the whole category is already here.
	let moreLine: String
	let onMore: () -> Void
	let focusedKey: FocusState<String?>.Binding
	let voFocus: AccessibilityFocusState<String?>.Binding
	let actions: (Channel, Bool) -> [RowAction]

	static func == (a: ChannelRows, b: ChannelRows) -> Bool {
		a.version == b.version && a.showGroup == b.showGroup && a.label == b.label && a.moreLine == b.moreLine
	}

	var body: some View {
		List {
			ForEach(channels) { ch in row(ch) }
			if !moreLine.isEmpty {
				// A real row, not a scroll trigger: VoiceOver reaches it with one swipe and it
				// doubles what is shown, so the whole category stays reachable.
				Button { onMore() } label: { RowLabel(line1: L("more"), line2: moreLine) }
					.row(Format.sentences([L("more"), moreLine]), actions: [])
			}
		}
		.listStyle(.plain)
		.accessibilityLabel(label)
		// A row insert or delete animation for a whole category is thousands of rows at once.
		.transaction { $0.animation = nil }
	}

	private func row(_ ch: Channel) -> some View {
		let _ = SwitchTiming.row()
		let model = AppModel.shared
		let fav = favs.contains(ch.key)
		let nn = ch.isLive ? model.library.epg.nowNext(ch) : nil
		// Just what is on and until when; next and the description are under Details.
		let line2 = nn?.now.map { L("until", $0.title, Format.time($0.stop)) } ?? (showGroup ? ch.group : "")
		let speech = Format.sentences([fav ? "\(ch.name), \(L("favorite"))" : ch.name, line2])
		return Button { model.open(ch) } label: {
			RowLabel(line1: fav ? L("favorite_name", ch.name) : ch.name, line2: line2)
		}
		.row(speech, actions: actions(ch, fav))
		.siriChannel(ch, active: focusedKey.wrappedValue == ch.key || voFocus.wrappedValue == ch.key)
		.focused(focusedKey, equals: ch.key)
		.accessibilityFocused(voFocus, equals: ch.key)
	}
}
