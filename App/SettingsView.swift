import SwiftUI
import UIKit
import UniformTypeIdentifiers
import IPTVCore

/// Options. Saved when the screen is left: no Save button to hunt for.
struct SettingsView: View {
	@EnvironmentObject private var model: AppModel
	@Environment(\.openURL) private var openURL
	@State private var preferAd = true
	@State private var keywords = ""
	@State private var external = false
	@State private var showUrl = false
	@State private var speakSubs = true
	@State private var announceLevel = 2
	@State private var days = ""
	@State private var buffer = ""
	@State private var maxBuffer = ""
	@State private var prePad = ""
	@State private var postPad = ""
	@State private var status = ""
	@State private var exporting = false
	@State private var importing = false
	@State private var exportDoc = SettingsFile(data: Data())

	private var prefs: Prefs { model.prefs }

	var body: some View {
		Form {
			Section {
				Toggle(L("prefer_ad"), isOn: $preferAd).accessibilityLabel(L("prefer_ad"))
				LabeledField(label: L("preferred_tracks"), text: $keywords, prompt: L("preferred_tracks_hint"))
			} header: { Text(L("audio_heading")).accessibilityAddTraits(.isHeader) }

			Section {
				Toggle(L("use_external_player"), isOn: $external).accessibilityLabel(L("use_external_player"))
				Toggle(L("show_stream_url"), isOn: $showUrl).accessibilityLabel(L("show_stream_url"))
				Toggle(L("speak_subtitles"), isOn: $speakSubs).accessibilityLabel(L("speak_subtitles"))
				Picker(L("announcements"), selection: $announceLevel) {
					Text(L("announce_none")).tag(0)
					Text(L("announce_errors")).tag(1)
					Text(L("announce_important")).tag(2)
					Text(L("announce_detailed")).tag(3)
				}
				.accessibilityLabel(L("announcements"))
				#if os(tvOS)
				.pickerStyle(.navigationLink)
				#else
				.pickerStyle(.inline)
				#endif
				numberField(L("buffer_seconds"), $buffer, decimal: true)
				numberField(L("max_buffer_seconds"), $maxBuffer, decimal: true)
			} header: { Text(L("playback_heading")).accessibilityAddTraits(.isHeader) }

			Section {
				numberField(L("guide_days"), $days)
			} header: { Text(L("guide_heading")).accessibilityAddTraits(.isHeader) }

			Section {
				numberField(L("pre_padding"), $prePad)
				numberField(L("post_padding"), $postPad)
			} header: { Text(L("recordings")).accessibilityAddTraits(.isHeader) }

			Section {
				#if os(tvOS)
				Button(L("language")) { openSettings() }
				#else
				// iOS keeps a per-app language in the Settings app, under this app.
				Button(L("language")) { openSettings() }
				Button(L("export_settings")) {
					save()
					do {
						exportDoc = SettingsFile(data: try prefs.export())
						exporting = true
					} catch { say(L("settings_failed", error.localizedDescription)) }
				}
				Button(L("import_settings")) { importing = true }
				#endif
				StatusLine(text: status)
			} header: { Text(L("backup_heading")).accessibilityAddTraits(.isHeader) }
		}
		.navigationTitle(L("settings"))
		.onAppear(perform: load)
		.onDisappear(perform: save)
		#if !os(tvOS)
		.fileExporter(isPresented: $exporting, document: exportDoc, contentType: .json, defaultFilename: "accessible-iptv-settings.json") { result in
			switch result {
			case .success: say(L("settings_exported"))
			case .failure(let e): say(L("settings_failed", e.localizedDescription))
			}
		}
		.fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
			do {
				let url = try result.get()
				let ok = url.startAccessingSecurityScopedResource()
				defer { if ok { url.stopAccessingSecurityScopedResource() } }
				try prefs.importSettings(Data(contentsOf: url))
				prefs.lastEpgImport = 0
				model.sourcesChanged = true
				load()
				say(L("settings_imported"))
			} catch {
				say(L("settings_failed", error.localizedDescription))
			}
		}
		#endif
	}

	private func numberField(_ label: String, _ text: Binding<String>, decimal: Bool = false) -> some View {
		#if os(tvOS)
		LabeledField(label: label, text: text)
		#else
		LabeledField(label: label, text: text, keyboard: decimal ? .decimalPad : .numberPad)
		#endif
	}

	private func openSettings() {
		if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
	}

	private func say(_ s: String) { status = s; announce(s) }

	private func load() {
		preferAd = prefs.preferAudioDescription
		keywords = prefs.audioKeywords
		external = prefs.useExternalPlayer
		showUrl = prefs.showStreamUrl
		speakSubs = prefs.speakSubtitles
		announceLevel = min(3, max(0, prefs.announceLevel))
		days = String(prefs.epgDaysAhead)
		buffer = plain(prefs.bufferSeconds)
		maxBuffer = plain(prefs.maxBufferSeconds)
		prePad = String(prefs.prePadMinutes)
		postPad = String(prefs.postPadMinutes)
	}

	private func save() {
		prefs.preferAudioDescription = preferAd
		prefs.audioKeywords = keywords.trimmingCharacters(in: .whitespaces)
		prefs.useExternalPlayer = external
		prefs.showStreamUrl = showUrl
		prefs.speakSubtitles = speakSubs
		prefs.announceLevel = announceLevel
		let d = Int(days.trimmingCharacters(in: .whitespaces)).map { min(14, max(1, $0)) } ?? 2
		if d != prefs.epgDaysAhead { prefs.lastEpgImport = 0 } // re-import with the new window
		prefs.epgDaysAhead = d
		// Desktop _apply_internal_player_bounds: max in (0, 300], base > 0 and never above max.
		let mx = number(maxBuffer).map { $0 <= 0 ? Prefs.defaultMaxBuffer : min($0, 300) } ?? prefs.maxBufferSeconds
		let base = min(number(buffer).map { $0 <= 0 ? Prefs.defaultBuffer : $0 } ?? prefs.bufferSeconds, mx)
		prefs.maxBufferSeconds = mx
		prefs.bufferSeconds = base
		// Desktop schedule padding: 0 to 180 minutes each side.
		prefs.prePadMinutes = Int(prePad.trimmingCharacters(in: .whitespaces)).map { min(180, max(0, $0)) } ?? 0
		prefs.postPadMinutes = Int(postPad.trimmingCharacters(in: .whitespaces)).map { min(180, max(0, $0)) } ?? 2
	}

	/// Accepts "2.5" and "2,5": decimal keypads type the local separator.
	private func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

	/// "6" rather than "6.0" in the field.
	private func plain(_ v: Double) -> String { v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v) }
}

/// The exported settings JSON, for the system file exporter.
struct SettingsFile: FileDocument {
	static var readableContentTypes: [UTType] { [.json] }
	let data: Data
	init(data: Data) { self.data = data }
	init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
	func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
