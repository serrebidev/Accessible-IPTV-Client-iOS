#if canImport(Speech) && !os(tvOS)
import AVFoundation
import Speech
import SwiftUI

/// The Voice button: the system speech recogniser's best guess goes into the search field.
/// Press again (or pause) to stop. Port of the Android RecognizerIntent search.
@MainActor
final class VoiceSearch: ObservableObject {
	@Published private(set) var listening = false
	private let engine = AVAudioEngine()
	private var request: SFSpeechAudioBufferRecognitionRequest?
	private var task: SFSpeechRecognitionTask?
	private var silence: Task<Void, Never>?

	func toggle(heard: @escaping (String) -> Void, status: @escaping (String) -> Void) {
		if listening { stop(); return }
		SFSpeechRecognizer.requestAuthorization { auth in
			Task { @MainActor in
				guard auth == .authorized, let rec = SFSpeechRecognizer(), rec.isAvailable else { status(L("voice_unavailable")); return }
				AVAudioApplication.requestRecordPermission { ok in
					Task { @MainActor in
						guard ok else { status(L("voice_unavailable")); return }
						do { try self.start(rec, heard: heard, status: status) } catch { status(L("voice_unavailable")) }
					}
				}
			}
		}
	}

	private func start(_ rec: SFSpeechRecognizer, heard: @escaping (String) -> Void, status: @escaping (String) -> Void) throws {
		// The permission hops are slow enough to press Voice again during them, and a second tap
		// on the input node is an Objective-C exception, which no catch can take back.
		if listening { stop() }
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
		try session.setActive(true, options: .notifyOthersOnDeactivation)
		let req = SFSpeechAudioBufferRecognitionRequest()
		req.shouldReportPartialResults = true
		request = req
		let input = engine.inputNode
		input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
		engine.prepare()
		do { try engine.start() } catch {
			// The tap stays on the node after a failed start, and the next press would tap it again.
			input.removeTap(onBus: 0)
			request = nil
			throw error
		}
		listening = true
		status(L("voice_prompt"))
		task = rec.recognitionTask(with: req) { result, error in
			Task { @MainActor in
				if let r = result {
					heard(r.bestTranscription.formattedString)
					self.armSilence()
					if r.isFinal { self.stop() }
				}
				if error != nil { self.stop() }
			}
		}
		armSilence()
	}

	/// Two quiet seconds end the search, like the system recogniser does.
	private func armSilence() {
		silence?.cancel()
		silence = Task {
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			if !Task.isCancelled { stop() }
		}
	}

	func stop() {
		guard listening else { return }
		listening = false
		silence?.cancel()
		engine.stop()
		engine.inputNode.removeTap(onBus: 0)
		request?.endAudio()
		task?.finish()
		request = nil
		task = nil
		try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
	}
}
#endif
