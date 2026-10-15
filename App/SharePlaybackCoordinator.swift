import AVFoundation
import CoreMedia
import GroupActivities

/// SharePlay controls VLC through Apple's custom-player coordinator.
/// shortcut: VLC starts and seeks asynchronously; sample-accurate sync needs a clock-driven renderer.
@MainActor
final class SharePlaybackCoordinator: NSObject, AVPlaybackCoordinatorPlaybackControlDelegate {
	private weak var controller: PlayerController?
	private let identifier: String
	private var closed = false
	private var suspension: AVCoordinatedPlaybackSuspension?
	private var recovery: AVCoordinatedPlaybackSuspension?
	private var pending: Completion?
	private var task: Task<Void, Never>?
	lazy var coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)

	@MainActor private final class Completion {
		private var handler: (@Sendable () -> Void)?
		init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
		func finish() {
			let callback = handler
			handler = nil
			callback?()
		}
	}

	init(controller: PlayerController, identifier: String) {
		self.controller = controller
		self.identifier = identifier
		super.init()
	}

	func join<Activity: GroupActivity>(_ session: GroupSession<Activity>) {
		guard !closed, let controller else { return }
		var timebase: CMTimebase?
		let created = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
			sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
		guard created == 0, let timebase else { return }
		let seconds = controller.sharedPlaybackTime
		let rate = controller.sharedPlaybackRate
		guard seconds.isFinite, rate.isFinite else { return }
		CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
		CMTimebaseSetRate(timebase, rate: Double(rate))
		coordinator.transitionToItem(withIdentifier: identifier, proposingInitialTimingBasedOn: timebase)
		coordinator.coordinateWithSession(session)
	}

	func play() {
		guard !closed else { return }
		if recovery != nil, controller?.sharedPlaybackFailed == true {
			controller?.recoverSharedPlayback()
		}
		coordinator.coordinateRateChange(to: 1)
	}

	func pause() {
		guard !closed else { return }
		coordinator.coordinateRateChange(to: 0)
	}

	func suspend() {
		guard !closed, suspension == nil else { return }
		suspension = coordinator.beginSuspension(for: .audioSessionInterrupted)
		cancelPending()
	}

	func endSuspension() {
		let previous = suspension
		suspension = nil
		previous?.end()
	}

	/// Called after VLC opens or recovers; never end a buffering suspension on a timer alone.
	func reapply() {
		guard !closed, controller?.sharedPlaybackReady == true else { return }
		let previous = recovery
		recovery = nil
		previous?.end()
		coordinator.reapplyCurrentItemStateToPlaybackControlDelegate()
	}

	func close() {
		guard !closed else { return }
		closed = true
		cancelPending()
		coordinator.transitionToItem(withIdentifier: nil, proposingInitialTimingBasedOn: nil)
		endSuspension()
		let previous = recovery
		recovery = nil
		previous?.end()
		controller = nil
	}

	private func cancelPending() {
		task?.cancel()
		task = nil
		let previous = pending
		pending = nil
		previous?.finish()
	}

	private func accept(_ command: AVDelegatingPlaybackCoordinatorPlaybackControlCommand,
		completion: @escaping @Sendable () -> Void) -> Completion? {
		guard !closed, suspension == nil, recovery == nil,
			command.expectedCurrentItemIdentifier == identifier, controller != nil else {
			completion()
			return nil
		}
		cancelPending()
		let result = Completion(completion)
		pending = result
		return result
	}

	private func recover() {
		guard !closed, recovery == nil else { return }
		recovery = coordinator.beginSuspension(for: .stallRecovery)
		controller?.recoverSharedPlayback()
	}

	private func waitUntilReady(until dueDate: Date? = nil) async -> Bool {
		let timeout = min(30, max(0, dueDate?.timeIntervalSinceNow ?? 30))
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		while !Task.isCancelled, !closed {
			if controller?.sharedPlaybackReady == true { return true }
			if controller?.sharedPlaybackFailed != false || ProcessInfo.processInfo.systemUptime >= deadline {
				recover()
				return false
			}
			do { try await Task.sleep(nanoseconds: 100_000_000) }
			catch { return false }
		}
		return false
	}

	private func completeWhenReady(until dueDate: Date?, completion: Completion) {
		task = Task { @MainActor [weak self] in
			defer { completion.finish() }
			_ = await self?.waitUntilReady(until: dueDate)
		}
	}

	nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
		didIssue command: AVDelegatingPlaybackCoordinatorPlayCommand,
		completionHandler: @escaping @Sendable () -> Void) {
		Task { @MainActor [weak self] in
			guard let self else { completionHandler(); return }
			guard let completion = accept(command, completion: completionHandler) else { return }
			let hostTime = CMTimeGetSeconds(command.hostClockTime)
			let itemTime = CMTimeGetSeconds(command.itemTime)
			let rate = command.rate
			guard hostTime.isFinite, itemTime.isFinite, rate.isFinite else {
				recover()
				completion.finish()
				return
			}
			controller?.performSharedPause(temporary: true)
			task = Task { @MainActor [weak self] in
				defer { completion.finish() }
				let preparedAt = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
				// Prepare the seek while there is still time to buffer before the scheduled start.
				if self?.controller?.sharedPlaybackSeekable == true {
					self?.controller?.performSharedSeek(seconds: max(0, itemTime + max(0, preparedAt - hostTime) * Double(rate)))
				}
				guard await self?.waitUntilReady() == true else { return }
				while !Task.isCancelled {
					let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
					let delay = hostTime - now
					if delay <= 0 { break }
					do { try await Task.sleep(nanoseconds: UInt64(min(delay, 1) * 1_000_000_000)) }
					catch { return }
				}
				guard !Task.isCancelled, self?.closed == false else { return }
				let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
				// Live providers expose no common seekable timeline; only their controls align.
				if now > hostTime, self?.controller?.sharedPlaybackSeekable == true {
					self?.controller?.performSharedSeek(seconds: max(0, itemTime + (now - hostTime) * Double(rate)))
				}
				guard await self?.waitUntilReady() == true else { return }
				guard !Task.isCancelled, self?.closed == false else { return }
				self?.controller?.performSharedPlay(rate: rate)
			}
		}
	}

	nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
		didIssue command: AVDelegatingPlaybackCoordinatorPauseCommand,
		completionHandler: @escaping @Sendable () -> Void) {
		Task { @MainActor [weak self] in
			guard let self else { completionHandler(); return }
			guard let completion = accept(command, completion: completionHandler) else { return }
			controller?.performSharedPause(temporary: command.shouldBufferInAnticipationOfPlayback)
			if command.shouldBufferInAnticipationOfPlayback {
				completeWhenReady(until: nil, completion: completion)
			} else { completion.finish() }
		}
	}

	nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
		didIssue command: AVDelegatingPlaybackCoordinatorSeekCommand,
		completionHandler: @escaping @Sendable () -> Void) {
		Task { @MainActor [weak self] in
			guard let self else { completionHandler(); return }
			guard let completion = accept(command, completion: completionHandler) else { return }
			let seconds = CMTimeGetSeconds(command.itemTime)
			if command.shouldBufferInAnticipationOfPlayback { controller?.performSharedPause(temporary: true) }
			if seconds.isFinite, controller?.sharedPlaybackSeekable == true {
				controller?.performSharedSeek(seconds: max(0, seconds))
				completeWhenReady(until: command.completionDueDate, completion: completion)
			} else if command.shouldBufferInAnticipationOfPlayback {
				completeWhenReady(until: command.completionDueDate, completion: completion)
			} else { completion.finish() }
		}
	}

	nonisolated func playbackCoordinator(_ coordinator: AVDelegatingPlaybackCoordinator,
		didIssue command: AVDelegatingPlaybackCoordinatorBufferingCommand,
		completionHandler: @escaping @Sendable () -> Void) {
		Task { @MainActor [weak self] in
			guard let self else { completionHandler(); return }
			guard let completion = accept(command, completion: completionHandler) else { return }
			controller?.performSharedPause(temporary: true)
			completeWhenReady(until: command.completionDueDate, completion: completion)
		}
	}
}
