# Picture workarounds: getting a libVLC-based iOS app's video onto a TV when AirPlay video may be impossible

Research date: 2026-10-16. Method: web_search (9 queries, numResults=10 each), GitHub `gh` CLI repo/issue searches (both `--sort stars` and `--sort updated`), web_fetch of key pages with quoted decisive sentences. Situation assumed throughout: iOS 17+ app on iPhone/iPad plays live MPEG-TS from an IPTV provider via libVLC (MobileVLCKit) into a UIView; the provider allows exactly ONE connection (the host device's session); the user wants the picture on an Apple TV or a Chromecast-class receiver; the user is blind and uses VoiceOver, so silent-failure modes are disqualifying unless detectable.

Verdict labels used below:
- **WORKS (no code)** — usable today, zero app code.
- **PLAUSIBLE (needs code)** — grounded in documented, shipped behavior.
- **UNPROVEN (needs code)** — no public evidence anyone has done this exact thing.
- **IMPOSSIBLE** — blocked by Apple/Google platform design or the single-connection rule.

---

## Q1: AirPlay screen mirroring via Control Center — what it does to libVLC video

### Takeaway
Screen mirroring captures the composited display (which includes libVLC's rendered video in its UIView) plus system audio, needs zero app code, and never touches the IPTV provider connection — it is the only option that works today with no code, and the one third-party guides recommend for VLC specifically.

### Cited Findings
- Apple's official steps: Control Center → Screen Mirroring → select TV/Mac; "mirror exactly what's on your device's screen"; footnote: "Some video apps might not support AirPlay. If you can't use AirPlay with a video app, check the App Store on your Apple TV to see if that app is available." — [Apple Support, "Use AirPlay to stream video or mirror the screen of your iPhone or iPad" (published 2026-05-15)](https://support.apple.com/en-us/102661)
- "Screen mirroring is the most reliable way to AirPlay from VLC on iPhone, because it bypasses VLC's built-in casting logic and uses Apple's native AirPlay protocol directly. The only trade-off is that it mirrors everything on your display, not just the video window." — [PigeonCast blog, 2025-11-07](https://pigeoncast.com/blogs/vlc-airplay)
- VLC iOS's own in-app AirPlay path is unreliable: "Over the last year AirPlay hasn't worked properly for me when connecting to my Apple TV, the usual casting button on a video through VLC just played the audio through the TV with the video continuing through my phone." — [r/VLC, "iOS AirPlay Issues After 3.4.0" (2023)](https://www.reddit.com/r/VLC/comments/13c0x6u/ios_airplay_issues_after_340/)
- An Apple Community poster describes mirroring an iPad to Apple TV and then playing in VLC successfully ("the video would play out with audio on the Apple TV") — [Apple Community thread](https://discussions.apple.com/thread/254842782)
- UxPlay (3,212★, pushed 2026-10-11) and derivatives turn a Mac/Windows/Linux/Android box into an AirPlay *mirroring* receiver, so the same no-code path works onto self-hosted hardware on the LAN — [FDH2/UxPlay](https://github.com/FDH2/UxPlay); [xenos1337/AirPlayServer (195★, pushed 2026-09-26)](https://github.com/xenos1337/AirPlayServer); [jqssun/android-airplay-server (605★, pushed 2026-08-23)](https://github.com/jqssun/android-airplay-server)

### Inferences
- Because mirroring is display-level (post-compositing), libVLC's OpenGL/Metal-rendered UIView is captured like any other pixels; no AVPlayer involvement. The black-screen/audio-only AirPlay failures reported for VLC are about VLC's *casting* path, not mirroring.
- The provider sees exactly one connection (the phone's); mirroring rides on the already-decoded picture.
- Latency: real but small (AirPlay mirroring is a live H.264 encode of the screen); fine for couch TV watching, not frame-accurate. No hard numbers found — see Gaps.
- VoiceOver: Screen Mirroring is system Control Center UI and VoiceOver-operable; audio switching gives immediate audible confirmation that the connection worked (unlike silent-black casting failures). Whether VoiceOver *speech* follows the TV or stays on the phone during mirroring is unverified — flag for on-device testing, since it affects whether the user loses speech while mirrored.

### Gaps
- No citable latency figures for AirPlay mirroring.
- No source found describing VoiceOver speech routing during screen mirroring.
- No source found on whether notification banners etc. are suppressed on the mirrored display (workaround: enable a Focus mode before mirroring — untested here).

---

## Q2: AVPlayer for live MPEG-TS, and the loopback-HLS + AirPlay question

### Takeaway
AVPlayer cannot play a raw live MPEG-TS stream; its live-format entry point is HLS only. A loopback (127.0.0.1) HLS server works for *local* playback but is a **hard dead end for AirPlay**: the Apple TV re-fetches the URL itself, and 127.0.0.1 on the Apple TV is the Apple TV.

### Cited Findings
- AVPlayer's documented scope: "Use an instance of AVPlayer to play local and remote file-based media, such as QuickTime movies and MP3 audio files, as well as audiovisual media served using HTTP Live Streaming." — [Apple, AVPlayer documentation](https://developer.apple.com/documentation/avfoundation/avplayer). Raw progressive MPEG-TS over HTTP is not in scope; TS is supported only as HLS segments.
- "HLS playback is supported natively on Apple devices via Safari on Desktop, iPadOS and iOS and via AVPlayer." — [Mux, "HLS vs. DASH"](https://www.mux.com/articles/hls-vs-dash-what-s-the-difference-between-the-video-streaming-protocols)
- The AirPlay handoff model, verified end-to-end on hardware by the BurstStream project (an iOS app that serves local HLS and AirPlays it): "Apple TV must be able to reach the HLS URL itself. This chapter explains the handoff and why a Mac LAN address works while `localhost` does not." and "localhost always means *this same machine*: … on Apple TV, it identifies the Apple TV." Implementation "validated end to end with a physical iPhone 14 Pro, an Apple TV, and the bilingual HLS stream served from the Mac over the local network." — [BurstStream AirPlay docs](https://oscast.github.io/burststream-ios/airplay.html)
- BurstStream's required app-side code is tiny: `AVRoutePickerView()` (+ `prioritizesVideoDevices = true`) and `player.allowsExternalPlayback = true`; observe `isExternalPlaybackActive`. — [BurstStream AirPlay docs](https://oscast.github.io/burststream-ios/airplay.html)
- Apple's archived AirPlay guide confirms the serving requirement: "For your server to work with AirPlay, it needs to be configured to send audio and video over HTTP." — [Apple Documentation Archive, "Preparing Your Media and Server for AirPlay"](https://developer-mdn.apple.com/library/archive/documentation/AudioVideo/Conceptual/AirPlayGuide/PreparingYourMediaforAirPlay/PreparingYourMediaforAirPlay.html)

### Inferences
- Verdict: AVPlayer-on-the-provider-URL is **IMPOSSIBLE** for raw MPEG-TS. Loopback-HLS + AirPlay is **IMPOSSIBLE** (URL handoff model). Loopback HLS *without* AirPlay is fine but pointless for the TV goal.
- The BurstStream architecture also proves the positive version: an HLS URL on a **LAN-reachable** address hands off to Apple TV cleanly (see Q3).
- Audio codec nuance for HLS on Apple devices: IPTV MPEG-TS commonly carries MP2 or AC-3 audio; AVPlayer HLS supports AAC and AC-3/E-AC-3, but MP2-in-HLS support is doubtful — a remux may need an audio transcode to AAC. Unverified — see unverified list.

### Gaps
- No primary Apple page fetched listing AVPlayer's supported containers exhaustively (developer.apple.com pages are JS-rendered and returned title-only to the fetcher); conclusion rests on the AVPlayer overview sentence plus consistent third-party documentation.
- MP2 audio inside HLS on AVPlayer: unverified either way.

---

## Q3: Second VLC instance (or other remuxer) serving HLS on the LAN for the receiver to fetch

### Takeaway
**PLAUSIBLE (needs code).** One provider connection lands on the phone; the phone remuxes TS→HLS (or serves the raw TS) and runs an HTTP server bound to its LAN address; Apple TV (via an AVPlayer that exists only as the AirPlay vehicle) or a Chromecast fetches from the phone. Credentials never leave the device and the provider still sees a single session. This is the strongest "real AirPlay video, no mirroring" architecture — but nobody ships it as a library, and whether MobileVLCKit can do the HLS-serving itself (livehttp sout) is unproven.

### Cited Findings
- Proof the handoff works from a LAN URL: BurstStream (Q2) — the same flow works with the server *on the phone* as long as the URL uses the phone's LAN IP, because "every participating device must be able to reach the stream URL." — [BurstStream AirPlay docs](https://oscast.github.io/burststream-ios/airplay.html)
- VLC's Chromecast output is already exactly this pattern — device-side serve, receiver-side fetch: "Internally, VLC uses this feature for chromecast. Chromecast expects an HTTP stream, so everything works normally when VLC sends an HTTP stream to the chromecast." — [VideoLAN docs, "Introduction to Transcoding"](https://prime-5.videolan.me/vlc-user/vlm_files/en/advanced/transcode/transcode_introduction.html)
- libVLC on iOS (MobileVLCKit) exists and is maintained (692★, pushed 2026-10-01) — [videolan/vlckit](https://github.com/videolan/vlckit)
- GitHub search "hls remux" (stars and updated sorts, 2026-10-16) returned **no mature library** — top hit is a 1★ VRChat-specific proxy; general-purpose iOS HLS-remux tooling does not exist off the shelf. "iptv hls proxy" surfaced only small server-side projects ([slavikme/iptv-proxy, 1★, pushed 2026-07-14](https://github.com/slavikme/iptv-proxy); [hamboy75/PtP-Proxy, 0★, pushed 2026-07-15](https://github.com/hamboy75/PtP-Proxy)).
- Independent existence proof of the architecture (macOS, same idea): "Native macOS app to play video links, IPTV and local files on Apple TV and AirPlay receivers." — [marcocosta97/airthrow, 1★, pushed 2026-10-15](https://github.com/marcocosta97/airthrow)

### Inferences
- Implementation sketch: keep libVLC as the on-device player; add a remux path (FFmpeg Kit, or a hand-rolled TS→HLS repackager — video H.264 can pass through; audio may need AAC transcode) writing segments+playlist; serve via an embedded HTTP server on the Wi-Fi interface; hand `http://<phone-LAN-IP>:port/master.m3u8` to an AVPlayer whose only job is AirPlay (hidden, `allowsExternalPlayback = true`, `AVRoutePickerView` in the UI). iOS needs the Local Network permission string (BurstStream notes this).
- A "second libVLC instance" doing `livehttp` stream-output would be elegant but there is **no evidence MobileVLCKit builds include livehttp/sout**; VLC for iOS exposes no streaming UI. Treat as UNPROVEN; FFmpeg-Kit or manual remux is the PLAUSIBLE variant.
- HLS adds segment-size latency (seconds) on top of the live stream — acceptable for TV viewing.
- VoiceOver: this option is fully controllable from inside the app, so status ("TV connected", errors) can be *announced* via VoiceOver rather than diagnosed from a black screen — a major advantage over VLC's flaky built-in casting.

### Gaps
- MobileVLCKit sout/livehttp availability: unverified.
- No published open-source iOS app found doing phone-side HLS remux for AirPlay handoff; airthrow is macOS. Feasibility inferred, not demonstrated on iOS.

---

## Q4: AirPlay 2 multi-room / driving AirPlay video directly from the app

### Takeaway
**IMPOSSIBLE** for a third-party app. AirPlay is a licensed proprietary protocol; apps only reach AirPlay through the system (AVPlayer external playback or mirroring). There is no public API to push arbitrary video (or frames) over AirPlay, and the reverse-engineered ecosystem is audio-only.

### Cited Findings
- "AirPlay is a proprietary wireless communication protocol stack/suite developed by Apple… the company has since licensed the AirPlay protocol stack to third-party manufacturers" (hardware licensees, not app developers) — [Wikipedia, AirPlay](https://en.wikipedia.org/wiki/AirPlay)
- Reverse-engineering effort explicitly scopes itself to audio: "AirPlay 2 is a family of protocols… However, my main focus is on the audio part." — [Emanuele Cozzi, AirPlay 2 Internals](https://emanuelecozzi.net/docs/airplay2)
- The most complete third-party AirPlay 2 *sender* implementation is realtime **audio only** (ALAC to Apple TV/HomePod) — [akustikrausch/airplay2-sender-cpp](https://github.com/akustikrausch/airplay2-sender-cpp)
- Plex, when replacing AVPlayer with their own player, state: "There are two other exceptions where Apples AVPlayer is needed: when using AirPlay and Picture in Picture." — [Plex Forums, "Early access … new Apple TV & iOS Video Player"](https://forums.plex.tv/t/early-access-for-plex-pass-users-to-new-apple-tv-ios-video-player/335439) (snippet captured via search; page is JS-rendered)
- A developer generating video frames on-device asks exactly our question ("render video frames directly to AirPlay… I know that I can use AirPlay with the HLS protocol") — [Stack Overflow #76450826](https://stackoverflow.com/questions/76450826/is-it-possible-render-video-frames-directly-to-airplay-from-an-ios-app) (page fetch timed out twice; premise captured via search snippet)

### Inferences
- Multi-room AirPlay 2 audio is a *system* feature; an app cannot enumerate or drive AirPlay 2 endpoints itself.
- Any "libVLC → AirPlay video without AVPlayer" design is a dead end; the mirroring path (Q1) is the only no-AVPlayer AirPlay route.

### Gaps
- The Stack Overflow thread's accepted answer text (fetch failed); the premise and the absence of any API in Apple docs both indicate "not possible."

---

## Q5: AVRouting / AVSystemRouting — adding a custom (non-AirPlay) protocol to the system route picker, e.g. to a self-hosted receiver

### Takeaway
**UNPROVEN (needs code), and mostly a dead end for this user.** AVRouting (iOS 16+) can add a third-party protocol to AVRoutePickerView, but it requires a Media Device Discovery Extension (a managed entitlement) and is built for *nearby* devices (Bonjour/Bluetooth) — a VPS on the internet doesn't fit the discovery model, and you still implement the entire media transport yourself. The newer AVSystemRouting (iOS 27) is consumer-side only and reportedly EU-gated.

### Cited Findings
- "Use the AVRouting framework to add third-party devices and protocols to AVRoutePickerView… If your app's bundle includes an extension with the Media Device Discovery Extension entitlement, the system runs the extension and adds its associated third-party protocol to the picker, **if the device resides nearby**." — [Apple, AVRouting](https://developer.apple.com/documentation/avrouting) (title-only fetch; text via [documentation mirror](https://raw.githubusercontent.com/incrediblecrab/apple-os-documentation/main/documentation/AVRouting.md))
- The discovery extension "search[es] the local network or paired Bluetooth devices for a specific media receiver" — [Apple, "Configuring media device discovery"](https://developer.apple.com/documentation/xcode/configuring-media-device-discovery)
- AVRouting surface is discovery/selection + events (`AVCustomRoutingController`, `AVCustomRoutingEvent`, custom action items); the framework provides **no media transport** — the app must stream to the device with its own protocol. — [AVRouting mirror](https://raw.githubusercontent.com/incrediblecrab/apple-os-documentation/main/documentation/AVRouting.md)
- Media Device (provider) side: "Your extension and the container app require the com.apple.developer.media-device-extension entitlement." — [Apple, MediaDevice](https://developer.apple.com/documentation/MediaDevice)
- AVSystemRouting (iOS 27): "lets a media app route playback to **non-AirPlay system routes** — third-party casting targets such as Google Cast / Chromecast and DLNA… Reportedly driven by the EU Digital Markets Act, this capability is **likely region-gated (EU)**… your app is the consumer (no extension); a casting-protocol vendor ships the route-provider extension." Also: absent from the Simulator SDK. — [Axiom, "System Media Routing (Casting Beyond AirPlay)"](https://charleswiltgen.github.io/Axiom/skills/integration/system-media-routing)
- AVSystemRouting's session model is again URL handoff: "AVSystemRouteSession — Starts playback using a URL and supported launch mode." — [AVSystemRouting mirror](https://raw.githubusercontent.com/incrediblecrab/apple-os-documentation/main/documentation/AVSystemRouting.md)

### Inferences
- Even if the entitlement is granted and the extension is written, the result is: the user picks your pseudo-device in the picker, and your app then streams to it *by its own means* — i.e., you're back to building Q3's server or a VPS relay anyway. The framework adds UI integration, not transport.
- For a self-hosted VPS receiver, plain HLS-over-HTTPS from the VPS (below, Q7/DIY option) achieves the same result with zero entitlements and works on every receiver that can open a URL.
- Verdict: **UNPROVEN** and low-value here; keep as "interesting, revisit if Apple opens it," not a plan.

### Gaps
- Whether the Media Device Discovery Extension entitlement requires an Apple approval request (docs describe the entitlement; the request flow wasn't fetciable — developer.apple.com is JS-rendered).
- AVSystemRouting region gating: single secondary source (Axiom); Apple's own pages not directly retrievable.

---

## Q6: Chromecast via VLCRendererDiscoverer, and live MPEG-TS on Chromecast

### Takeaway
**PLAUSIBLE (needs a small amount of code).** VLCKit ships renderer discovery (`VLCRendererDiscoverer`) and libVLC's Chromecast output serves the stream from the phone over local HTTP — so the Chromecast never contacts the IPTV provider and the single-connection rule holds. Google Cast officially supports the MP2T (MPEG-TS) container with H.264 video and HLS delivery, so live TS is in-spec. Caveat: VLC iOS's casting has repeated user reports of black-screen/audio-only failures — a silent-failure mode that must be actively detected and announced for a blind user.

### Cited Findings
- VLCKit exposes `VLCRendererDiscoverer` (`+list`, `-start`, `-renderers`, delegate callbacks for appeared/disappeared) and `VLCRendererItem` — [VLCKit class reference](https://videolan.videolan.me/VLCKit/interface_v_l_c_renderer_discoverer.html); [header source](https://code.videolan.org/videolan/VLCKit/-/blob/master/Headers/Public/VLCRendererDiscoverer.h)
- VLC's Chromecast mechanism: the device serves HTTP, the Chromecast fetches: "Chromecast expects an HTTP stream, so everything works normally when VLC sends an HTTP stream to the chromecast." — [VideoLAN docs](https://prime-5.videolan.me/vlc-user/vlm_files/en/advanced/transcode/transcode_introduction.html)
- Google Cast supported media: container formats include **MP2T**; "HEVC is not supported on Transport Stream containers"; HLS is a supported delivery method; H.264 High Profile supported across Chromecast generations (page updated 2024-09-18) — [Google, "Supported Media for Google Cast"](https://developers.google.com/cast/docs/media)
- VLC for iOS advertises Chromecast officially (and notably does **not** advertise AirPlay): "playback speed control and rendering through Chromecast" — [videolan.org, VLC for iOS download page](https://www.videolan.org/vlc/download-ios.html)
- Reliability problems in practice: "Its always comes this black screen without video but i can hear the Audio." — [r/Chromecast (2021)](https://www.reddit.com/r/Chromecast/comments/o9krvb/i_was_using_my_iphone_with_chromecast_for_vlc/); "Recently, my iPhone and iPad VLC apps no longer give me an option to cast to Chromecast. This worked for a long time, but recently stopped" — [r/VLC (2022)](https://www.reddit.com/r/VLC/comments/uhiyz5/ios_app_cannot_find_chromecast/)
- How-to asks confirm the API path (`setRenderer` on the player) is the intended integration — [Stack Overflow #75441202](https://stackoverflow.com/questions/75441202/how-to-connect-mobile-vlckit-media-to-chromecast) (fetch timed out; snippet only)
- Sender-side ecosystem: Google's official iOS Cast SDK is a closed-source CocoaPods binary (no official GitHub repo; only SPM re-packagings: [SRGSSR/GoogleCastSDK-ios-no-bluetooth, 4★, pushed 2024-07-01](https://github.com/SRGSSR/GoogleCastSDK-ios-no-bluetooth); [BookBeat fork, 0★, pushed 2026-03-26](https://github.com/BookBeat/GoogleCastSDK-ios-no-bluetooth)). A pure-Swift SDK-free sender appeared recently: [CreatureSurvive/SwiftCast, 0★, pushed 2026-09-27](https://github.com/CreatureSurvive/SwiftCast) ("Pure-Swift Google Cast (Chromecast) sender for iOS, macOS, tvOS and visionOS… No Google SDK").

### Inferences
- Code cost is genuinely low: discover renderers, let the user pick one, `player.setRenderer(item)`. libVLC handles any transcoding Chromecast needs.
- The blind-user risk is *detectability*, not capability: VLCKit exposes player/renderer events, so the app can announce "casting started/failed" instead of leaving a black TV screen. This is buildable and should be a hard requirement.
- Note the constraint: IPTV TS with H.264 video + MP2/AC-3 audio → Chromecast can take the TS container, but libVLC may transcode audio; expect startup delay of several seconds.

### Gaps
- No first-hand confirmation that MobileVLCKit's renderer path works for *live* TS specifically in current VLCKit builds (VLC iOS proves local files; Reddit shows flakiness).
- The Stack Overflow thread's answers weren't retrievable.

---

## Q7: Frame-level APIs — VideoToolbox, AVSampleBufferDisplayLayer, external display (UIScreen)

### Takeaway
**IMPOSSIBLE as an AirPlay feed** — none of these can hand video to a receiver. They only matter as building blocks of a DIY streaming pipeline (decode → re-encode → serve), which collapses into Q3. The one adjacent trick, UxPlay's `-hls` receiver mode, only supports the YouTube app.

### Cited Findings
- `AVSampleBufferDisplayLayer` is "An object that displays compressed or uncompressed video frames" — a local CALayer, with no AirPlay handoff; its AirPlay-adjacent use is PiP (`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:)`). — [Apple, AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer); [Apple, PiP content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/samplebufferdisplaylayer)
- The on-device-frame-generator SO question (Q4) shows the community position: generated/real-time video can reach AirPlay only via HLS, i.e., served HTTP. — [Stack Overflow #76450826](https://stackoverflow.com/questions/76450826/is-it-possible-render-video-frames-directly-to-airplay-from-an-ios-app)
- Apple's archived AirPlay guide's only non-AVPlayer integration is the *external display* window (separate UIScreen content while AirPlaying) — separate UI content, not a video transport. — [Apple Documentation Archive, "Enriching the AirPlay Experience in Your App"](https://developer-mdn.apple.com/library/archive/documentation/AudioVideo/Conceptual/AirPlayGuide/EnrichYourAppforAirPlay/EnrichYourAppforAirPlay.html)
- UxPlay's non-mirror video mode: "With the new '-hls' option, UxPlay now also supports non-Mirror AirPlay video streaming (where the client controls a web server on the AirPlay server that directly receives HLS content)… This currently only supports streaming of YouTube videos." — [antimof/UxPlay README](https://github.com/antimof/UxPlay); man page: "hls … YouTube app video only" — [Tribblix uxplay(1)](https://www.tribblix.org/man/man1/uxplay.html)

### Inferences
- A custom-protocol DIY variant that *is* realistic: phone serves HLS (Q3) and, if the receiver must be reached over the internet, relays it through the user's VPS (phone pushes once, or VPS pulls from phone via tunnel); any HLS-capable receiver (smart-TV browser, custom Chromecast receiver app, Apple TV app, VLC on a TV box) plays the VPS URL. No Apple/Google cast SDKs involved; single provider connection preserved. Verdict: **PLAUSIBLE (needs the most code + VPS bandwidth + adds latency)**.
- The external-display window approach is **UNPROVEN→effectively dead**: it presupposes an AirPlay session exists (i.e., mirroring, which already shows the video) and would require decoded frames out of libVLC — high effort, zero gain over Q1.

### Gaps
- Whether any app still uses the legacy second-UIScreen-over-AirPlay path on iOS 17+ (no current evidence found).

---

## Q8: What VLC, Infuse, nPlayer (and Plex) actually offer for AirPlay

### Takeaway
Every successful third-party player converges on the same answer: AirPlay video goes through AVPlayer(-compatible H.264/HLS) or, failing that, screen mirroring. VLC iOS offers Chromecast rendering and no working AirPlay video.

### Cited Findings
- VLC for iOS: feature list mentions "rendering through Chromecast"; no AirPlay video feature is listed. — [videolan.org](https://www.videolan.org/vlc/download-ios.html)
- VLC iOS AirPlay is audio-only/flaky in user reports (2023): casting button "just played the audio through the TV with the video continuing through my phone." — [r/VLC](https://www.reddit.com/r/VLC/comments/13c0x6u/ios_airplay_issues_after_340/)
- nPlayer's own documentation: "In case of unsupported codec or subtitles, you have to use AirPlay Mirroring" — their AirPlay works for "H.264 video codec file". — [nPlayer Help, AirPlay](https://help.nplayer.tv/en/36-2/etc/airplay/index.html)
- Infuse: AirPlay troubleshooting centers on audio format options (Dolby Digital 5.1), i.e., it works only within AVPlayer-compatible media; HEVC AirPlay users report audio-only — [Firecore Support, "AirPlay Isn't Working"](https://support.firecore.com/hc/en-us/articles/215090937-AirPlay-Isn-t-Working); [r/appletv HEVC AirPlay thread](https://www.reddit.com/r/appletv/comments/1397xyk/airplaying_hevch265_problems/). Infuse's real answer to "iPhone files on the TV" is its native tvOS app, not AirPlay — [r/appletv](https://www.reddit.com/r/appletv/comments/vuthg3/how_to_play_ipadiphone_files_on_the_apple_tv_with/)
- Plex replaced AVPlayer with a custom player but kept AVPlayer "when using AirPlay and Picture in Picture." — [Plex Forums](https://forums.plex.tv/t/early-access-for-plex-pass-users-to-new-apple-tv-ios-video-player/335439) (snippet)

### Inferences
- Market consensus validates the ranking below: mirroring first, Chromecast-style device-side serving second, AVPlayer-with-HLS third, everything else fringe.

---

## GitHub ecosystem scan (run 2026-10-16 via `gh search repos`)

### Chromecast sender libraries
`--sort stars`: [castjs/castjs](https://github.com/castjs/castjs) 300★ (pushed 2026-08-02, browser sender); [shokimble/cast-canvas](https://github.com/shokimble/cast-canvas) 33★ (2016-10-31); [eriklax/c8tsender](https://github.com/eriklax/c8tsender) 30★ (2017-01-09); everything else ≤8★ and stale.
`--sort updated`: [CreatureSurvive/SwiftCast](https://github.com/CreatureSurvive/SwiftCast) 0★ (pushed 2026-09-27) — pure-Swift iOS Google Cast sender, no Google SDK, very new; [Evidlo/nichromecast](https://github.com/Evidlo/nichromecast) 1★ (2026-08-09); castjs 300★ (2026-08-02).
Google Cast SDK for iOS: closed-source; only SPM wrappers exist ([SRGSSR](https://github.com/SRGSSR/GoogleCastSDK-ios-no-bluetooth) 4★, 2024-07-01; [BookBeat fork](https://github.com/BookBeat/GoogleCastSDK-ios-no-bluetooth) 0★, 2026-03-26).
**Reading:** for VLCKit users the built-in `VLCRendererDiscoverer` beats any third-party sender; there is no thriving iOS Chromecast-sender OSS ecosystem.

### AirPlay receivers
`--sort stars`: [FDH2/UxPlay](https://github.com/FDH2/UxPlay) 3,212★ (pushed 2026-10-11) — the canonical open AirPlay mirroring/audio receiver (Mac/Win/Linux; RPi-friendly); [amitv87/PiP](https://github.com/amitv87/PiP) 854★ (2026-08-30, macOS receiver); [jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server) 605★ (2026-08-23, Android); [xenos1337/AirPlayServer](https://github.com/xenos1337/AirPlayServer) 195★ (2026-09-26, Windows); [gbulog/pcairplay](https://github.com/gbulog/pcairplay) 113★ (2026-07-24, Windows wrapper on UxPlay); [prat3ik/iMirror](https://github.com/prat3ik/iMirror) 55★ (2026-08-23, Android TV).
`--sort updated`: [marcocosta97/airthrow](https://github.com/marcocosta97/airthrow) 1★ (2026-10-15) — macOS IPTV→Apple TV local-server app (architecture proof for Q3); [ZC635/AirPlay-Receiver](https://github.com/ZC635/AirPlay-Receiver) 10★ (2026-10-15); [mkatadev/GoogleTVAirPlay](https://github.com/mkatadev/GoogleTVAirPlay) 0★ (2026-10-14); plus many small Android-TV forks.
**Reading:** if the user ever attaches a small box/PC to the TV, an UxPlay-class receiver turns Q1 (mirroring) into a self-hosted solution on the LAN with zero app code. Receivers are LAN/mDNS-bound; none bridge to a VPS.

### HLS remuxing / IPTV proxy
`--sort stars` and `--sort updated` for "hls remux": nothing mature (top: a 1★ VRChat YouTube proxy, 2026-09-04; 1★ Wildberries downloader). "iptv hls proxy": [slavikme/iptv-proxy](https://github.com/slavikme/iptv-proxy) 1★ (2026-07-14); [hamboy75/PtP-Proxy](https://github.com/hamboy75/PtP-Proxy) 0★ (2026-07-15).
**Reading:** no off-the-shelf iOS TS→HLS remux library; Q3 means writing the remux (FFmpeg Kit or manual TS repackaging) yourself.

### libVLC itself
[videolan/vlckit](https://github.com/videolan/vlckit) 692★ (pushed 2026-10-01); [videolan/vlc-ios](https://github.com/videolan/vlc-ios) mirror active. No AirPlay issues on the GitHub mirror (issues live on VideoLAN's GitLab).

---

## Ranked options with verdicts

1. **AirPlay screen mirroring (Control Center) — WORKS, no code.** Captures libVLC's rendered picture and system audio; single provider connection untouched; VoiceOver-operable system UI; audible confirmation when TV audio starts. Downsides: mirrors everything (use a Focus mode), slight latency, phone stays awake, 16:9 letterboxing. Also works onto self-hosted UxPlay-class receivers on the LAN.
2. **Chromecast via VLCKit's VLCRendererDiscoverer — PLAUSIBLE, small code cost.** libVLC serves the stream from the phone; Chromecast never contacts the provider; Google Cast supports MP2T/H.264 and HLS in-spec. Must build VoiceOver-announced success/failure detection because VLC-class casting fails silently (black screen) in some builds.
3. **On-device TS→HLS remux + LAN HTTP server + AVPlayer-as-AirPlay-vehicle — PLAUSIBLE, largest in-app code cost.** The only design that yields *real* AirPlay video (not mirroring) while preserving one provider connection and keeping credentials on-device. Proven handoff model (BurstStream); remux layer must be written; watch audio codecs (MP2 → AAC transcode likely).
4. **DIY HLS relay via the user's VPS to any URL-capable receiver — PLAUSIBLE, most infrastructure code.** Works for Apple TV (custom tvOS app or any HLS player), smart-TV browsers, custom Chromecast receiver; no entitlement or cast SDK needed; costs upload bandwidth and adds latency.
5. **AVRouting custom route (iOS 16+) / AVSystemRouting + Media Device extension (iOS 27) — UNPROVEN.** Adds your protocol to the system picker but provides no transport, requires a managed discovery-extension entitlement, targets *nearby* devices (not a VPS), and AVSystemRouting is reportedly EU-gated and consumer-side only. Revisit later; not a plan.
6. **Second libVLC instance with livehttp sout — UNPROVEN** (no evidence MobileVLCKit ships sout/livehttp); superseded by option 3's FFmpeg/manual remux.
7. **AVPlayer directly on the provider's raw MPEG-TS — IMPOSSIBLE** (AVPlayer plays file-based media and HLS only).
8. **Loopback (127.0.0.1) HLS + AirPlay — IMPOSSIBLE** (Apple TV re-fetches the URL; localhost on the TV is the TV).
9. **Driving AirPlay 2 video/multi-room directly from the app — IMPOSSIBLE** (licensed protocol; no public API; reverse-engineered implementations are audio-only).
10. **Frame-level push (VideoToolbox/AVSampleBufferDisplayLayer) or external-display window to AirPlay — IMPOSSIBLE** as a transport (no API; external screen presupposes mirroring anyway).
11. **Receiver opens its own connection to the IPTV provider — EXCLUDED** by the single-session rule (and would expose credentials).

---

## What remains unverified

- MobileVLCKit (iOS) inclusion of sout/livehttp (needed for the "second VLC instance" variant of HLS remux).
- First-hand confirmation that VLCKit renderer casting works reliably for *live* MPEG-TS on current builds (VLC iOS proves the general path for files; Reddit shows intermittent black-screen failures).
- Whether MP2 audio inside TS-derived HLS plays on AVPlayer/Apple TV (assume an AAC transcode is required until tested).
- VoiceOver speech routing during AirPlay screen mirroring (does speech stay on the phone or move to the TV?), and VoiceOver behavior of VLC iOS's casting UI.
- The Media Device Discovery Extension entitlement request/approval process (Apple docs pages are JS-rendered; only catalog text was retrievable).
- AVSystemRouting EU region-gating — single secondary source (Axiom); Apple's own guide pages not directly fetched.
- The answer content of Stack Overflow #76450826 and #75441202 (fetches timed out; premises captured from search snippets).
- The full Plex forum text (JS-rendered; claim rests on a search snippet).
- Hard latency numbers for AirPlay mirroring and for VLC Chromecast casting startup.
