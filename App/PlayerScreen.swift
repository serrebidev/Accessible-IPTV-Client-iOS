import SwiftUI
import UIKit
import VLCKit
import IPTVCore

/// libVLC draws into a plain UIView.
private struct VideoView: UIViewRepresentable {
	let player: VLCMediaPlayer
	func makeUIView(context: Context) -> UIView {
		let v = UIView()
		v.backgroundColor = .black
		v.isAccessibilityElement = false
		player.drawable = v
		return v
	}
	func updateUIView(_ v: UIView, context: Context) {}
}

/// The player: real, always-visible buttons; no auto-hiding overlay, no icon-only controls.
struct PlayerScreen: View {
	@StateObject private var c: PlayerController
	@EnvironmentObject private var model: AppModel
	@Environment(\.dismiss) private var dismiss
	@Environment(\.scenePhase) private var phase
	@State private var choosing: Choosing?
	@State private var pickingSubtitle = false
	@AccessibilityFocusState private var voFocus: Target?
	@FocusState private var focus: Target?

	enum Target: Hashable { case pause, full, video }

	private enum Choosing: Identifiable {
		case audio([PlayerController.TrackChoice]), subtitles([PlayerController.TrackChoice])
		#if !os(tvOS)
		case cast([PlayerController.Renderer])
		#endif
		var id: Int {
			switch self {
			case .audio: return 0
			case .subtitles: return 1
			#if !os(tvOS)
			case .cast: return 2
			#endif
			}
		}
	}

	init(request: PlayRequest) { _c = StateObject(wrappedValue: PlayerController(request: request)) }

	var body: some View {
		VStack(spacing: 0) {
			video
			if !c.subtitle.isEmpty {
				// Subtitle text for everyone; spoken by the controller when Speak subtitles is on.
				Text(c.subtitle).font(.title3).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal)
			}
			if !c.fullscreen {
				VStack(alignment: .leading, spacing: 4) {
					Text(c.nowPlaying).frame(maxWidth: .infinity, alignment: .leading)
					if !c.status.isEmpty { Text(c.status).frame(maxWidth: .infinity, alignment: .leading) }
				}
				.padding(.horizontal)
				.padding(.top, 6)
				controls
			}
		}
		.foregroundStyle(.white)
		.background(Color.black.ignoresSafeArea())
		.tint(.white)
		.accessibilityAction(.magicTap) { c.togglePause() }
		.onAppear {
			c.start()
			// Start on Pause, so the first activation pauses or resumes.
			focus = .pause
			Task { try? await Task.sleep(nanoseconds: 600_000_000); voFocus = .pause }
		}
		.onDisappear { c.close() }
		.onChange(of: phase) { _, p in c.scene(p) }
		#if os(tvOS)
		.onPlayPauseCommand { c.togglePause() }
		.onExitCommand { if c.fullscreen { setFullscreen(false) } else { dismiss() } }
		#endif
		.sheet(item: $choosing) { choice in
			switch choice {
			case .audio(let list):
				ChoiceSheet(title: L("audio_track"), options: list.map(\.name), selected: list.firstIndex { $0.track.isSelected }) { c.selectAudio(list[$0]) }
			case .subtitles(let list):
				let file = canPickFiles ? [L("subtitle_file")] : []
				ChoiceSheet(title: L("subtitles"), options: [L("subtitles_off")] + list.map(\.name) + file,
					selected: list.firstIndex { $0.track.isSelected }.map { $0 + 1 } ?? 0) { i in
					if i == 0 { c.selectSubtitle(nil) } else if i <= list.count { c.selectSubtitle(list[i - 1]) } else { pickingSubtitle = true }
				}
			#if !os(tvOS)
			case .cast(let list):
				ChoiceSheet(title: L("cast"), options: list.map(\.name)) { c.cast(to: list[$0]) }
			#endif
			}
		}
		#if !os(tvOS)
		.fileImporter(isPresented: $pickingSubtitle, allowedContentTypes: [.data, .plainText]) { r in
			if case .success(let url) = r { c.loadSubtitle(url) }
		}
		#endif
	}

	private var canPickFiles: Bool {
		#if os(tvOS)
		return false
		#else
		return true
		#endif
	}

	@ViewBuilder private var video: some View {
		if c.fullscreen {
			// Full screen hides every control. The video is one labelled button, so VoiceOver,
			// a remote or a tap brings the controls back.
			Button { setFullscreen(false) } label: {
				VideoView(player: c.player).frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.buttonStyle(.plain)
			.accessibilityLabel(L("video_full_screen"))
			.keyboardShortcut(.escape, modifiers: [])
			.focused($focus, equals: .video)
			.accessibilityFocused($voFocus, equals: .video)
			.ignoresSafeArea()
		} else {
			VideoView(player: c.player)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.accessibilityHidden(true)
		}
	}

	private var controls: some View {
		// Scrolls sideways on a narrow phone; VoiceOver and the remote bring hidden buttons into view.
		ScrollView(.horizontal) {
			HStack {
				Button(L(c.failed ? "retry" : c.isPlaying ? "pause" : "play")) { c.togglePause() }
					.focused($focus, equals: .pause)
					.accessibilityFocused($voFocus, equals: .pause)
				Button(L("audio_track")) { chooseAudio() }
					.keyboardShortcut("a", modifiers: [])
				Button(L("subtitles")) { chooseSubtitles() }
					.keyboardShortcut("s", modifiers: [])
				Button(L("record")) { record() }
				#if !os(tvOS)
				Button(L(c.casting == nil ? "cast" : "stop_casting")) { cast() }
				#endif
				Button(L("full_screen")) { setFullscreen(true) }
					.keyboardShortcut("f", modifiers: [])
					.focused($focus, equals: .full)
					.accessibilityFocused($voFocus, equals: .full)
				Button(L("close")) { dismiss() }
					.keyboardShortcut(.escape, modifiers: [])
			}
			.buttonStyle(.bordered)
			.padding(6)
		}
	}

	private func setFullscreen(_ on: Bool) {
		c.fullscreen = on
		let target: Target = on ? .video : .full
		focus = target
		Task {
			try? await Task.sleep(nanoseconds: 300_000_000)
			voFocus = target
		}
	}

	private func chooseAudio() {
		let list = c.audioTracks()
		if list.isEmpty { c.say(L("no_audio_tracks"), 1) } else { choosing = .audio(list) }
	}

	private func chooseSubtitles() {
		let list = c.textTracks()
		if list.isEmpty && !canPickFiles { c.say(L("no_subtitles"), 1) } else { choosing = .subtitles(list) }
	}

	private func record() {
		guard !c.request.catchup, let ch = c.channel, ch.isLive else { c.say(L("cannot_record_this"), 1); return }
		model.recorder.start(ch, title: model.library.epg.nowNext(ch).now?.title ?? "")
		c.say(L("recording_channel", ch.name), 2)
	}

	#if !os(tvOS)
	private func cast() {
		if c.localFile { c.say(L("cast_local_file"), 1); return }
		if c.casting != nil { c.cast(to: nil); return }
		let list = c.renderers()
		if list.isEmpty { c.say(L("cast_none"), 1) } else { choosing = .cast(list) }
	}
	#endif
}
