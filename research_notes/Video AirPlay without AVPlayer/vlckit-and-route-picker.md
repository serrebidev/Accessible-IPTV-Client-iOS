# libVLC/VLCKit AirPlay capability, and AirPlay for non-AVPlayer audio

Research date: 2026-10-15/16. Two questions the earlier run left open, both with web search
(10 results per query), GitHub and source inspection where it was reachable.

## Q1: Does libVLC / VLCKit 4 have its own AirPlay sender, and does it carry video?

### Takeaway
In the libVLC source that could be read, renderer discovery is Chromecast only. AirPlay is not a
renderer protocol, and no AirPlay or RAOP module appears in the build manifests that were
inspected. VLCKit 4.0.0-a22's iOS build could not be verified: VideoLAN's GitLab answers bots,
and the public build script is a rolling `master` script, not the a22 one. So there is no evidence
that `VLCRendererDiscoverer.list()` returns AirPlay receivers, and no evidence for the reverse
either — the app's own history is the best evidence available: the Cast list on a real device is
the check.

### Cited findings
- `modules/services_discovery/microdns.c` (rolling `master`) declares both a services-discovery and
  a `renderer_discovery` submodule, and its renderer protocol table has one entry: Chromecast,
  advertised as `_googlecast._tcp.local`, creating items with the `"chromecast"` protocol id and
  the `cc_demux` filter. No AirPlay entry. —
  [videolan/vlc modules/services_discovery/microdns.c](https://github.com/videolan/vlc/blob/master/modules/services_discovery/microdns.c)
- `services_discovery/meson.build` and `Makefile.am` list `microdns` when its dependency is present
  and a Bonjour module on Darwin (ordinary service discovery, not AirPlay renderers); neither
  `stream_out/Makefile.am` nor `audio_output/Makefile.am` lists an AirPlay or RAOP module. —
  [services_discovery/meson.build](https://github.com/videolan/vlc/blob/master/modules/services_discovery/meson.build)
- The `4.0.0-a22` tag exists and VLCKit describes itself as a wrapper for macOS, iOS and tvOS, but
  the tag page exposes no date and no module list for the pinned iOS build. —
  [videolan/vlckit, tag 4.0.0-a22](https://github.com/videolan/vlckit/tree/4.0.0-a22)
- VideoLAN's 2018 statement of intent — "Support for AirPlay will be available in libvlc and
  VLCKit 4.0… It will allow you play anything from any source on Apple TV and if needed, will
  convert the media on-the-fly. Thus, AirPlay support will match what's possible with Chromecast
  right now" — is the only AirPlay statement found, and it predates the 4.0 series by years. It
  describes a sender that re-serves the stream from the device, not an Apple API. —
  [Stack Overflow #52473769](https://stackoverflow.com/questions/52473769/do-mobilevlckit-support-airplay-option-in-ios)
  (snippet only: the page returned 504 on fetch)

### Gaps
- The a22 iOS binary's module list, and the runtime value of `VLCRendererDiscoverer.list()` on iOS.
  code.videolan.org is bot-protected and its issue pages could not be read, so no maintainer
  statement could be quoted on AirPlay video versus audio on mobile.
- Whether VLC for iOS currently lists AirPlay receivers in its own cast list. User reports exist,
  but the pages were not readable, so they are not counted as evidence here.

## Q2: Does an in-app AirPlay route picker do anything for audio that is not AVPlayer's?

### Takeaway
Yes, for audio. Apple's category guidance puts `.playback` among the categories that support both
mirrored and non-mirrored AirPlay, and Apple's 2023 guidance treats "set the session, offer
`AVRoutePickerView`" as the ordinary route setup, with AVPlayer/`AVSampleBufferAudioRenderer`
reserved for *enhanced buffering*. Nothing in that path requires AVPlayer. The picker is not an
AirPlay-video shim, though: it cannot carry a picture for any renderer that is not an AVPlayer.

### Cited findings
- ".ambient, .soloAmbient and .playback support both mirrored and non-mirrored AirPlay";
  `.playAndRecord` supports only mirrored AirPlay and `.multiRoute` does not allow AirPlay at all.
  — [Apple Technical Q&A QA1803](https://developer.apple.com/library/archive/qa/qa1803/_index.html)
  (2014-01-15; category-level guidance, old but not contradicted)
- Apple's own AirPlay guidance: configure the audio session for the intended use and provide
  `AVRoutePickerView` for route selection; use AVPlayer/AVQueuePlayer, or
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`, for the *enhanced buffering*
  experience. —
  [WWDC23 session 10238, "Enhance the audio experience with AirPlay"](https://developer.apple.com/videos/play/wwdc2023/10238/)
- The picker is a UIKit control whose documented model is a user tap; there is no public API to
  present the system route sheet programmatically, and the widely used "tap an internal subview"
  trick is not a documented API. —
  [AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview) —
  see also [react-native-video #3119](https://github.com/TheWidlarzGroup/react-native-video/issues/3119)
  (request for programmatic presentation, 2023-05-05)
- VoiceOver: a 2025 Apple Developer Forums report shows a standalone picker being operable while
  the same picker nested inside an outer SwiftUI `Button` did not respond to a VoiceOver
  double-tap. Keep the picker as its own control. —
  [Apple Developer Forums thread 795191](https://developer.apple.com/forums/thread/795191)
  (July–August 2025)
- `AVRouteDetector` reports only that more than one route exists; it does not report AirPlay 1
  versus AirPlay 2, and no public API exposes the protocol version or buffering capability of a
  route. — [AVRouteDetector](https://developer.apple.com/documentation/avfoundation/avroutedetector)
- Counter-evidence, and how to read it: a media_kit maintainer said "Not possible without AVPlayer"
  about a Flutter AirPlay plugin that did not recognise its libmpv playback. That is a statement
  about one integration, not about session routing: it does not overturn the category guidance, and
  the category guidance does not guarantee any particular AudioUnit setup. Which combination this
  app has is a device test. — [media-kit #721](https://github.com/media-kit/media-kit/issues/721)
  (2024-03-04)
- VoiceOver speech has its own Audio Destination control and normally stays on the phone during
  AirPlay, but users report cases where it followed the receiver until a restart. —
  [AppleVis, "iPhone's VoiceOver speech now routing to AirPlay devices"](https://www.applevis.com/forum/ios-ipados/iphones-voiceover-speech-now-routing-airplay-devices)
  (2021, iOS 13/14-era user report)

### What follows for this app
- libVLC plays through the app's `.playback` / `.moviePlayback` session, so a standalone
  `AVRoutePickerView` is expected to move the *sound* to an AirPlay or AirPlay 2 device. Expected,
  not proven: the exact AudioUnit/session combination is not covered by any Apple document found,
  so it needs one device test — the sound either moves to the Apple TV or it does not.
- Nothing here provides a video path. `allowsExternalPlayback`, AVPlayerItem and the receiver
  fetching the URL are what AirPlay video is made of (see airplay-architecture.md).
