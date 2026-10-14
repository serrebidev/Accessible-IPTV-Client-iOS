import SwiftUI
import UniformTypeIdentifiers
import IPTVCore

/// Playlist Manager: Xtream Codes, Stalker portals, M3U URLs and M3U files, each with an
/// optional guide URL.
struct SourcesView: View {
	@EnvironmentObject private var model: AppModel
	@State private var sources: [Source] = []
	@State private var status = ""
	@State private var editing: Editing?
	@State private var deleting: Source?
	@State private var picking = false

	struct Editing: Identifiable {
		let id = UUID()
		let existing: Source?
		let type: String
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ScrollView(.horizontal) {
				HStack {
					Button(L("add_xtream")) { editing = Editing(existing: nil, type: Source.typeXtream) }
					Button(L("add_m3u")) { editing = Editing(existing: nil, type: Source.typeM3U) }
					#if !os(tvOS)
					Button(L("add_m3u_file")) { picking = true }
					#endif
					Button(L("add_stalker")) { editing = Editing(existing: nil, type: Source.typeStalker) }
				}
				.buttonStyle(.bordered)
			}
			StatusLine(text: status)
			Text(P("source_count", sources.count)).font(.headline).heading()
			List(sources) { s in
				let kind = s.isXtream ? L("xtream_at", s.url) : s.isStalker ? L("stalker_at", s.url) : s.isFile ? L("m3u_file") : L("m3u_playlist")
				Button { editing = Editing(existing: s, type: s.type) } label: { RowLabel(line1: s.name, line2: kind) }
					.row("\(s.name), \(kind)", actions: [
						RowAction(L("edit")) { editing = Editing(existing: s, type: s.type) },
						RowAction(L("delete")) { deleting = s },
					])
			}
			.listStyle(.plain)
		}
		.padding(.horizontal)
		.navigationTitle(L("playlists_and_guides"))
		.onAppear(perform: refresh)
		.sheet(item: $editing) { e in SourceEditor(existing: e.existing, type: e.type) { save($0) } }
		.alert(L("delete"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { s in
			Button(L("delete"), role: .destructive) {
				model.prefs.sources = model.prefs.sources.filter { $0.id != s.id }
				model.library.forgetCache(s)
				model.sourcesChanged = true
				refresh()
				say(L("source_deleted", s.name))
			}
			Button(L("cancel"), role: .cancel) {}
		} message: { s in
			Text(L("delete_source_q", s.name))
		}
		#if !os(tvOS)
		.fileImporter(isPresented: $picking, allowedContentTypes: [.m3uPlaylist, .plainText, .data]) { result in
			guard case .success(let url) = result else { return }
			do {
				save(Source(id: UUID().uuidString, type: Source.typeM3U, name: url.deletingPathExtension().lastPathComponent, url: try Bookmarks.make(url)))
			} catch {
				say(L("load_errors", error.localizedDescription))
			}
		}
		#endif
	}

	private func say(_ s: String) { status = s; announce(s) }

	private func refresh() {
		sources = model.prefs.sources
		if sources.isEmpty { say(L("no_sources")) }
	}

	private func save(_ src: Source) {
		model.prefs.sources = model.prefs.sources.filter { $0.id != src.id } + [src]
		model.library.forgetCache(src)
		model.prefs.lastEpgImport = 0 // new source, new guide
		model.sourcesChanged = true
		refresh()
		say(L("source_saved", src.name))
	}
}

/// Add or edit one playlist. Errors sit under their field, and VoiceOver is moved there.
private struct SourceEditor: View {
	let existing: Source?
	let type: String
	let onSave: (Source) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var url = ""
	@State private var mac = ""
	@State private var user = ""
	@State private var pass = ""
	@State private var epg = ""
	@State private var errors: [Field: String] = [:]
	@AccessibilityFocusState private var focus: Field?

	enum Field: Hashable { case url, mac, user, pass }

	private var xtream: Bool { type == Source.typeXtream }
	private var stalker: Bool { type == Source.typeStalker }
	private var file: Bool { existing?.isFile == true }

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					LabeledField(label: L("field_name"), text: $name)
					if !file {
						LabeledField(label: L(xtream ? "field_server" : stalker ? "field_portal" : "field_url"), text: $url, error: errors[.url])
							.accessibilityFocused($focus, equals: .url)
					}
					if stalker {
						LabeledField(label: L("field_mac"), text: $mac, prompt: L("mac_hint"), error: errors[.mac])
							.accessibilityFocused($focus, equals: .mac)
					}
					if (xtream || stalker) && !file {
						LabeledField(label: L("field_username"), text: $user, error: errors[.user])
							.textContentType(.username)
							.accessibilityFocused($focus, equals: .user)
						LabeledField(label: L("field_password"), text: $pass, secure: true, error: errors[.pass])
							.textContentType(.password)
							.accessibilityFocused($focus, equals: .pass)
					}
					LabeledField(label: L("field_epg"), text: $epg)
				}
				.padding()
			}
			.navigationTitle(L(existing != nil ? "edit_source" : xtream ? "add_xtream" : stalker ? "add_stalker" : "add_m3u"))
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button(L("save")) { save() } }
			}
		}
		.onAppear {
			if let e = existing { name = e.name; url = e.isFile ? "" : e.url; mac = e.mac; user = e.username; pass = e.password; epg = e.epgUrl }
		}
	}

	private func save() {
		// A whole panel link pasted as the server carries the login: fill it in.
		if xtream && user.trimmingCharacters(in: .whitespaces).isEmpty, let c = Xtream.credentialsFromUrl(url) {
			url = c.server; user = c.user; pass = c.pass
		}
		var e: [Field: String] = [:]
		if !file && url.trimmingCharacters(in: .whitespaces).isEmpty { e[.url] = L("field_required") }
		if stalker && mac.trimmingCharacters(in: .whitespaces).range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) == nil { e[.mac] = L("mac_invalid") }
		if xtream && user.trimmingCharacters(in: .whitespaces).isEmpty { e[.user] = L("field_required") }
		if xtream && pass.isEmpty { e[.pass] = L("field_required") }
		errors = e
		if let first = [Field.url, .mac, .user, .pass].first(where: { e[$0] != nil }) {
			focus = first
			announce(e[first]!)
			return
		}
		let typed = url.trimmingCharacters(in: .whitespaces)
		let server: String
		if file { server = existing!.url }
		else if xtream { server = Xtream.normalizeServer(typed) }
		else if stalker { server = Xtream.withScheme(typed) }
		// "example.com/list.m3u" failed with "no protocol" on Android.
		else if !typed.contains("://") { server = "http://\(typed)" }
		else { server = typed }
		let trimmedName = name.trimmingCharacters(in: .whitespaces)
		onSave(Source(
			id: existing?.id ?? UUID().uuidString,
			type: type,
			name: trimmedName.isEmpty ? (URL(string: server)?.host ?? server) : trimmedName,
			url: server,
			username: user.trimmingCharacters(in: .whitespaces),
			password: pass,
			epgUrl: epg.trimmingCharacters(in: .whitespaces),
			mac: mac.trimmingCharacters(in: .whitespaces).uppercased()
		))
		dismiss()
	}
}
