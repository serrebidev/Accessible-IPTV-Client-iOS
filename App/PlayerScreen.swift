import SwiftUI
import UIKit
import VLCKit
import IPTVCore

/// libVLC draws into a plain UIView.
private struct VideoView: UIViewRepresentable {
	let controller: PlayerController
	private final class Host: UIView {
		var surface: UIView?
		override func didMoveToWindow() {
			super.didMoveToWindow()
			guard window != nil, let surface else { return }
			surface.removeFromSuperview()
			addSubview(surface)
			surface.frame = bounds
			surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		}
	}
	func makeUIView(context: Context) -> UIView {
		let v = Host()
		v.surface = controller.videoSurface
		v.backgroundColor = .black
		v.isAccessibilityElement = false
		return v
	}
	func updateUIView(_ v: UIView, context: Context) {}
}

/// The same playback session and video surface, reachable while browsing any screen.
struct MiniPlayer: View {
	@ObservedObject var c: PlayerController
	@EnvironmentObject private var model: AppModel
	@Environment(\.dynamicTypeSize) private var typeSize

	var body: some View {
		VStack(spacing: 0) {
			Divider()
			if typeSize.isAccessibilitySize {
				VStack(alignment: .leading) { openButton; transport }.padding()
			} else {
				HStack(spacing: 12) { openButton; transport }.padding(8)
			}
		}
		.background(.background)
		.accessibilityElement(children: .contain)
		.accessibilityAction(.magicTap) { c.togglePause() }
	}

	private var openButton: some View {
		Button { model.playerPresented = true } label: {
			HStack(spacing: 12) {
				if !typeSize.isAccessibilitySize {
					VideoView(controller: c)
						.frame(width: 88, height: 50).clipped().accessibilityHidden(true)
				}
				VStack(alignment: .leading) {
					Text(c.request.title).font(.headline).lineLimit(2)
					Text(c.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityLabel("\(L("open_player")), \(c.request.title)")
		.accessibilityValue(c.status)
		.siriChannel(c.channel)
	}

	private var transport: some View {
		HStack {
			Button { c.togglePause() } label: {
				Label(L(c.failed ? "retry" : c.isPaused ? "play" : "pause"), systemImage: c.isPaused || c.failed ? "play.fill" : "pause.fill")
			}
			Button { model.stopPlayback() } label: { Label(L("stop_playback"), systemImage: "stop.fill") }
		}
		.labelStyle(.iconOnly)
		.buttonStyle(.bordered)
		#if !os(tvOS)
		.controlSize(.large)
		#endif
	}
}

/// The player: real, always-visible buttons; no auto-hiding overlay, no icon-only controls.
struct PlayerScreen: View {
	@ObservedObject var c: PlayerController
	@EnvironmentObject private var model: AppModel
	@State private var choosing: Choosing?
	@State private var pickingSubtitle = false
	@AccessibilityFocusState private var voFocus: Target?
	@FocusState private var focus: Target?

	enum Target: Hashable { case pause, full, video }

	private enum Choosing: Identifiable {
		case audio([PlayerController.TrackChoice]), subtitles([PlayerController.TrackChoice])
		#if os(iOS)
		case cast([PlayerController.Renderer])
		#endif
		var id: Int {
			switch self {
			case .audio: return 0
			case .subtitles: return 1
			#if os(iOS)
			case .cast: return 2
			#endif
			}
		}
	}

	var body: some View {
		Group {
			#if os(iOS)
			if c.fullscreen {
				video
			} else {
				ScrollView {
					VStack(spacing: 16) {
						HStack {
							Button { model.minimizePlayer() } label: { Label(L("minimize_player"), systemImage: "chevron.down") }
								.key(.escape)
							Spacer()
							Button(L("stop_playback")) { model.stopPlayback() }
						}
						.padding(.horizontal)
						VideoView(controller: c).aspectRatio(16 / 9, contentMode: .fit).accessibilityHidden(true)
						VStack(alignment: .leading, spacing: 8) {
							Text(c.nowPlaying).font(.title2).accessibilityAddTraits(.isHeader)
							if !c.status.isEmpty { Text(c.status) }
							if !c.subtitle.isEmpty { Text(c.subtitle).font(.body.weight(.semibold)) }
						}
						.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
						nativeControls
					}
					.padding(.vertical)
				}
			}
			#else
		VStack(spacing: 0) {
			video
			if !c.subtitle.isEmpty {
				// Subtitle text for everyone; spoken by the controller when Speak subtitles is on.
				Text(c.subtitle).font(.body.weight(.semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal)
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
			#endif
		}
		.foregroundStyle(.white)
		.background(Color.black.ignoresSafeArea())
		.accessibilityAction(.magicTap) { c.togglePause() }
		.siriChannel(c.channel)
		.onAppear {
			// Start on Pause, so the first activation pauses or resumes.
			focus = .pause
			Task { try? await Task.sleep(nanoseconds: 600_000_000); voFocus = .pause }
		}
		#if os(tvOS)
		.onPlayPauseCommand { c.togglePause() }
		.onExitCommand { if c.fullscreen { setFullscreen(false) } else { model.minimizePlayer() } }
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
			#if os(iOS)
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

	#if os(iOS)
	private var nativeControls: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
			Button(L(c.failed ? "retry" : c.isPaused ? "play" : "pause")) { c.togglePause() }
				.focused($focus, equals: .pause).accessibilityFocused($voFocus, equals: .pause)
			Button(L("audio_track")) { chooseAudio() }.key("a")
			Button(L("subtitles")) { chooseSubtitles() }.key("s")
			Button(L("record")) { record() }
			Button(L(c.casting == nil ? "cast" : "stop_casting")) { cast() }
			Button(L("full_screen")) { setFullscreen(true) }.key("f")
				.focused($focus, equals: .full).accessibilityFocused($voFocus, equals: .full)
		}
		.buttonStyle(.bordered).controlSize(.large).padding(.horizontal)
	}
	#endif

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
				VideoView(controller: c).frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			.buttonStyle(.plain)
			.accessibilityLabel(L("video_full_screen"))
			.key(.escape)
			.focused($focus, equals: .video)
			.accessibilityFocused($voFocus, equals: .video)
			.ignoresSafeArea()
		} else {
			VideoView(controller: c)
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
					.key("a")
				Button(L("subtitles")) { chooseSubtitles() }
					.key("s")
				Button(L("record")) { record() }
				#if os(iOS)
				Button(L(c.casting == nil ? "cast" : "stop_casting")) { cast() }
				#endif
				Button(L("full_screen")) { setFullscreen(true) }
					.key("f")
					.focused($focus, equals: .full)
					.accessibilityFocused($voFocus, equals: .full)
				Button(L("close")) { model.minimizePlayer() }
					.key(.escape)
				Button(L("stop_playback")) { model.stopPlayback() }
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

	#if os(iOS)
	private func cast() {
		if c.localFile { c.say(L("cast_local_file"), 1); return }
		if c.casting != nil { c.cast(to: nil); return }
		let list = c.renderers()
		if list.isEmpty { c.say(L("cast_none"), 1) } else { choosing = .cast(list) }
	}
	#endif
}

private extension View {
	/// A plain-key shortcut on iPad and Vision Pro keyboards; Apple TV has none.
	@ViewBuilder func key(_ k: KeyEquivalent) -> some View {
		#if os(tvOS)
		self
		#else
		keyboardShortcut(k, modifiers: [])
		#endif
	}
}
