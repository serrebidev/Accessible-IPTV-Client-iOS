
	@Test func forcedBackendOverridesRouting() {
		PlaybackBackend.forced = .vlc
		defer { PlaybackBackend.forced = nil }
		#expect(PlaybackBackend.preferred(for: "https://example.test/live/video.ts") == .vlc)
		#expect(PlaybackBackend.preferred(for: "https://example.test/movie.m3u8") == .vlc)
	}
