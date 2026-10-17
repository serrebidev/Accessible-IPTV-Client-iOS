# Can this app put its picture on an Apple TV? AirPlay video for a libVLC player

Question put to the research: the player is libVLC (VLCKit 4) rendering into a `UIView`, audio
through the app's own AudioUnit on an `AVAudioSession` (`.playback`, `.moviePlayback`), playing
live MPEG-TS from an IPTV provider on iOS 17+. Can the app send **video** to an AirPlay or
AirPlay 2 receiver, and if not, what actually works?

Method: four research streams (Apple documentation and WWDC transcripts, VideoLAN sources and
issue trackers, GitHub surveys sorted by stars and by most recently updated, and workaround
enumeration), 10 search results per query, with the decisive pages read rather than summarised
from snippets. The three earlier notes and the follow-up note are listed at the end.

## The answer

**In-app AirPlay video is impossible for this app.** AirPlay video is a property of AVPlayer: the
asset is modelled as a URL, the receiver becomes the player of that stream, and the API surface
that makes it happen (`allowsExternalPlayback`, `AVPlayerItem`, `AVPlayerViewController`) has no
equivalent for an app that decodes and draws its own frames. There is no public iOS API that hands
an already-decoded video stream, or its frames, to AirPlay. Apple's only documented "bring your own
data" AirPlay path is audio-only (`AVSampleBufferAudioRenderer`). Independent teams that tried the
same thing reached the same conclusion: KSPlayer's maintainer ("Apple only allows AVPlayer to do
AirPlay video"), media_kit ("audio only, the video remains on the device"), Twilio's answer to a
WebRTC casting request (mirroring, or repackage into an HLS asset for AVPlayer), and a 2026 field
report from a custom FFmpeg/VideoToolbox pipeline on iOS 27 where audio reached the receiver via
the audio session while the picture stayed in a local `AVSampleBufferDisplayLayer`.

**Three things do work**, in order of cost:

1. **Screen Mirroring — works today, no code.** Control Center → Screen Mirroring captures the
   composited display, so libVLC's `UIView` goes to the TV with the sound. The provider sees one
   connection, and nothing in the app changes. Costs: the whole screen is mirrored (use a Focus
   mode), mirroring-grade quality and latency, phone stays awake. This is what every guide
   recommends for VLC on iOS, and it also works onto self-hosted receivers (UxPlay and friends).
2. **Sound-only AirPlay through the system picker — small code, and now implemented.** Apple's
   category guidance says `.playback` supports AirPlay; VLCKit's existing Chromecast path is
   untouched. The picture stays on the device. This is what the app now offers next to Playback
   destination, and it is the honest ceiling of in-app AirPlay here.
3. **Real AirPlay video — the largest build, and only by handing the receiver a URL it can fetch.**
   Remux the provider stream to HLS on the phone, serve it over the LAN from the phone's own
   address, and give that URL to an AVPlayer whose only job is external playback. The single
   provider connection is preserved and credentials stay on the device. The handoff model is
   proven (a small project does exactly this end to end with an Apple TV), but no off-the-shelf
   iOS TS→HLS library exists, MP2 audio very likely needs an AAC transcode, and a localhost URL is
   a dead end — the Apple TV re-fetches the URL, and `localhost` on the Apple TV is the Apple TV.

**AirPlay 2 adds nothing here.** Multi-room and buffered audio are system features of the route;
no public API lets an app enumerate or drive AirPlay 2 endpoints, the reverse-engineered ecosystem
is audio-only, and `AVRouteDetector` only reports that more than one route exists. The system
picker lists AirPlay and AirPlay 2 receivers alike; the app does not choose between them.

## What the evidence rules out, with the reason

- **AVRoutePickerView carrying video.** It is route UI, not a pipeline. It exposes
  `player: AVPlayer?` — the player the routing is for. With no AVPlayer there is nothing video-shaped
  to hand over, so at most the app's audio follows the route.
- **libVLC's own renderer API as the answer.** The renderer API is real (`VLCRendererDiscoverer`,
  `VLCRendererItem`), and Chromecast genuinely works through it because libVLC re-serves the stream
  from the phone. But in the libVLC source that could be read, renderer discovery has one protocol
  table entry — Chromecast — and no AirPlay or RAOP module appears in the build manifests. VideoLAN's
  2018 statement that "AirPlay support will be available in libvlc and VLCKit 4.0" is the only
  statement found, it is years old, and it describes that same device-side re-serving model, not an
  Apple API. The a22 iOS build's module list could not be verified: VideoLAN's GitLab answers bots.
- **Frame-level routes.** `AVSampleBufferDisplayLayer` has no external-playback member;
  AVPlayerLayer is bound to an AVPlayer; `AVDisplayManager` is about display modes;
  `AVOutputContext` route control on iOS was not found at all. Apple's flexible enhanced buffering
  ("apps that require control over I/O") is audio renderers only.
- **AVRouting / AVSystemRouting.** AVRouting (iOS 16+) adds a *third-party protocol* to the system
  picker through a Media Device Discovery Extension; it provides discovery, selection and playback
  arbitration, not transport. AVSystemRouting (iOS 27) keeps the URL-launch model and is reportedly
  EU-gated. Neither is a way to push frames to an Apple TV.
- **A hand-rolled AirPlay sender.** The open ecosystem is overwhelmingly receivers and audio
  senders. The only working video senders are URL-push (`play_url`-style, receiver fetches) and
  Linux screen-mirroring senders; AirPlay 2 video sending is implemented by nobody, and even the
  legacy URL-push path is regressing on tvOS 26.
- **AVPlayer on the provider URL.** AVPlayer plays file-based media and HLS, not raw live MPEG-TS,
  which is exactly why this app uses libVLC.

## What changed in the app because of this

- The Cast button is now **Playback destination**, and it still lists libVLC renderers
  (Chromecast-class) — that path is unchanged and still carries video, because the receiver fetches
  from the phone.
- A standalone **AirPlay** button (Apple's own `AVRoutePickerView`, its own control, so VoiceOver
  reaches it and the receiver list is iOS's) sits next to it. It carries sound only.
- When the route moves to an AirPlay receiver, the player says "Sound on <device>", because the
  picture staying behind is otherwise invisible to a listener.
- Help states the split in all 14 languages: Playback destination sends the stream to a Chromecast
  on the same network; AirPlay sends the sound and the picture stays on this device; Screen
  Mirroring in Control Center sends the picture.

## Open items, honestly

1. Whether libVLC's AudioUnit output actually follows an AirPlay route on the user's device. Apple's
   category guidance says a `.playback` session supports AirPlay and no Apple document requires
   AVPlayer for plain routing, but the exact combination is untested here. It is a one-minute test
   by ear: pick the Apple TV, and the sound either moves or it does not.
2. Whether the a22 VLCKit iOS build's `VLCRendererDiscoverer.list()` returns anything beyond
   Chromecast. The app can answer this on a device by opening Playback destination.
3. Whether MP2 audio in TS-derived HLS plays on an Apple TV without an AAC transcode (only matters
   for the remux-to-HLS option).
4. VoiceOver speech during mirroring: whether it stays on the phone (users report it normally does,
   with its own Audio Destination setting) — worth one check, since mirroring is the recommended
   picture path.

## Notes this report is built from

- `airplay-architecture.md` — what Apple requires for AirPlay video, the API surface that exists and
  does not, Control Center versus in-app routing, and what changed in iOS 17–27.
- `github-survey.md` — repositories sorted by stars and by last push: senders versus receivers, who
  has solved which hard part, and what the biggest and newest projects say about AirPlay 2.
- `picture-workarounds.md` — every realistic route to a TV for this exact app, with verdicts:
  which work with no code, which are plausible, which are unproven, and which are impossible.
- `vlckit-and-route-picker.md` — libVLC/VLCKit's own AirPlay capability, and whether an in-app
  route picker does anything for audio that AVPlayer did not produce.
