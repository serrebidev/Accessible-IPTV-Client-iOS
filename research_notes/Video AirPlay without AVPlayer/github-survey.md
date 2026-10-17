# GitHub survey: sending video to AirPlay without AVPlayer

Survey date: 2026-10-15. Method: 5 web searches (numResults=10 each) + `gh search repos` for 9 query terms in both sort orders (stars and updated), `gh search code` for `AVRoutePickerView`, `gh search issues`, `gh repo view` / `gh api` metadata and READMEs, and `web_fetch` of decisive issues. All star counts and push dates below were pulled live from the GitHub API on 2026-10-15.

## Ranked repository table (sender vs receiver, stars, last pushed, language, media)

### Senders (push media TO an AirPlay receiver)

| Repo | Stars | Last pushed | Lang | Platform | Sends | Evidence of working video |
|---|---|---|---|---|---|---|
| [owntone/owntone-server](https://github.com/owntone/owntone-server) | 2570 | 2026-10-15 | C | Linux/BSD/macOS server | Audio only (AirPlay 1+2) | Working, mature — audio only, no video |
| [postlund/pyatv](https://github.com/postlund/pyatv) | 1187 | 2026-08-14 | Python | Desktop/HA | Audio + **video via `play_url`** (receiver fetches the URL itself) | Working but fragile — see tvOS 26 regression below |
| [tomohiro/airplayer](https://github.com/tomohiro/airplayer) | 275 | 2022-05-27 | Ruby | macOS/Linux CLI | Video via URL push to Apple TV | Worked vs AirPlay 1-era Apple TVs; unmaintained since 2022 |
| [omarroth/doubletake](https://github.com/omarroth/doubletake) | 122 | 2026-10-04 | Go | Linux (X11/Wayland) | **Screen mirroring** (H.264/HEVC, FairPlay SAP, SRP-6a) | Working mirroring sender with a tested-device list (Apple TV 3/4K gens, Roku, Samsung, TCL, Hisense) — desktop-only |
| [akustikrausch/airplay2-sender-cpp](https://github.com/akustikrausch/airplay2-sender-cpp) | 73 | 2026-09-05 | C++ | Windows | Audio only (ALAC over encrypted RAOP/RTSP) | Working, "verified… proven in FXChainPlayer" — audio only |
| [lmcgartland/airplay2-rs](https://github.com/lmcgartland/airplay2-rs) | 109 | 2026-10-09 | Rust | macOS/Linux | Audio only (AirPlay 2 sender) | Alpha (Feb 2026): "Discovery, pairing, RTSP session setup, and audio streaming are functional… Many modules still contain `todo!()` stubs" |
| [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) | 39 | 2020-09-17 | Obj-C | — | AirPlay 2 sender skeleton | README is acknowledgements only; abandoned since 2020; no evidence it ever streamed |
| [openairplay/AirPlayAuth](https://github.com/openairplay/AirPlayAuth) | 97 | 2017-05-26 | Java | JVM | Pairing/auth helper only ("allows to pair with an AppleTV… in any app supporting streaming/casting") | Not a streamer; abandoned since 2017 |
| [marcocosta97/airthrow](https://github.com/marcocosta97/airthrow) | 1 | 2026-10-15 | Swift | **macOS** | Video links, local files, **IPTV/Xtream** to Apple TV | Uses **AVPlayer** (`PlaybackController.swift`: `let player: AVPlayer`, `allowsExternalPlayback`, `AVRoutePickerView`) — not a non-AVPlayer solution; macOS-only, brand new |
| [carlosciller/AirCiller](https://github.com/carlosciller/AirCiller) | 0 | 2026-10-15 | Swift | **macOS** | Local movies to Apple TV "over AirPlay 2" with HDR/Dolby Vision | README claims it; 0 stars, brand new, unverified; macOS-only |
| [aivanyuk/airkast](https://github.com/aivanyuk/airkast) | 0 | 2026-10-14 | Kotlin | Android/JVM | Video **URL push** + audio streaming | README: "Only three receivers have been checked… airkast does not mirror the screen, and streams only audio itself" — the TV downloads the URL; brand new, unverified |
| [sijow/gst-airplay](https://github.com/sijow/gst-airplay) | 96 | 2024-03-03 | C | Linux | — | **Mislabeled by search: it is a receiver** (`airplaysrc` GStreamer source "for receiving video streamed from Apple devices"), audio not supported |

### Receivers (act as the AirPlay target)

| Repo | Stars | Last pushed | Lang | Platform | Receives |
|---|---|---|---|---|---|
| [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync) | 8892 | 2026-10-15 | C | Linux/BSD/macOS | Audio only (AirPlay 1 + AirPlay 2 build) |
| [philippe44/AirConnect](https://github.com/philippe44/AirConnect) | 4201 | 2026-10-15 | C | Cross-platform bridge | Audio only (bridges AirPlay → UPnP/Sonos/Chromecast) |
| [xfirefly/Airplay-SDK](https://github.com/xfirefly/Airplay-SDK) | 4013 | 2026-09-26 | HTML (binaries) | Windows/Android/Linux | Mirroring + casting; **closed-source commercial SDK, sells protocol source** — claim, not verifiable code |
| [FDH2/UxPlay](https://github.com/FDH2/UxPlay) | 3212 | 2026-10-11 | C | Linux/macOS/Unix/Windows | Mirroring + audio + HLS video (YouTube); actively maintained fork, v1.74 experimental June 2026 |
| [antimof/UxPlay](https://github.com/antimof/UxPlay) | 2131 | 2026-04-04 | C | Linux/Unix | Original UxPlay; development moved to FDH2 |
| [openairplay/airplay2-receiver](https://github.com/openairplay/airplay2-receiver) | 2429 | 2026-06-29 | Python | Cross-platform | AirPlay 2 **audio** receiver (FairPlay v3, ALAC/AAC/OPUS/PCM); "experimental, yet fully functional"; no video |
| [amitv87/PiP](https://github.com/amitv87/PiP) | 854 | 2026-08-30 | C | macOS | AirPlay receiver (mirroring) + PiP |
| [leapbtw/uxplay-windows](https://github.com/leapbtw/uxplay-windows) | 803 | 2026-09-13 | C++ | Windows | UxPlay wrapper — mirroring receiver |
| [espes/Slave-in-the-Magic-Mirror](https://github.com/espes/Slave-in-the-Magic-Mirror) | 626 | 2017-11-16 | Python | Desktop | AirPlay mirroring receiver, WIP, abandoned since 2017 |
| [jqssun/android-airplay-server](https://github.com/jqssun/android-airplay-server) | 605 | 2026-08-23 | Kotlin | Android/Android TV | "First open-source AirPlay 2 receiver for Android" (mirroring, video, audio), based on UxPlay — Android-only |
| [rbouteiller/airplay-esp32](https://github.com/rbouteiller/airplay-esp32) | 596 | 2026-10-15 | C | ESP32 | AirPlay 2 **audio** receiver (speaker) |
| [openairplay/goplay2](https://github.com/openairplay/goplay2) | 423 | 2023-04-21 | Go | Cross-platform | AirPlay 2 audio receiver; stalled 2023 |
| [neon443/AirAP](https://github.com/neon443/AirAP) | 412 | 2026-10-15 | Swift | **iOS** | AirPlay **audio** receiver on iPhone (wraps shairplay/Airstream); audio only |
| [serezhka/java-airplay-server](https://github.com/serezhka/java-airplay-server) | 394 | 2022-12-14 | Java | JVM | "Acts like Apple TV" receiver; stalled 2022 |
| [SteeBono/airplayreceiver](https://github.com/SteeBono/airplayreceiver) | 244 | 2023-02-07 | C# | macOS/Win/Linux | AirPlay 2 mirroring/audio receiver; stalled 2023 |

## Key Question 1 — Which repos implement a video SENDER vs a receiver?

### Takeaway
The open ecosystem is overwhelmingly receivers and audio senders. The only working **video** senders are (a) URL-push senders (pyatv, tomohiro/airplayer, airkast — the receiver downloads the file itself, so no frames leave the sender) and (b) screen-mirroring senders (doubletake on Linux). No repository implements a sender that pushes arbitrary decoded/encoded video frames to an AirPlay receiver the way AVPlayer does on Apple platforms.

### Cited Findings
- doubletake README: "AirPlay screen mirroring sender for Linux. Streams your desktop to an Apple TV using the AirPlay mirroring protocol… FairPlay SAP authentication (clean Go implementation)… SRP-6a pairing" with a tested-device list — [doubletake](https://github.com/omarroth/doubletake). Desktop-only (Linux).
- pyatv docs show video "sending" is `play_url=http://…mp4` — the Apple TV fetches the URL; pyatv also streams audio files via RAOP — [pyatv atvremote docs](https://pyatv.dev/documentation/atvremote/).
- airkast README: "To a TV, your app sends a URL. The receiver downloads and plays the stream itself… airkast does not mirror the screen, and streams only audio itself" — [airkast](https://github.com/aivanyuk/airkast).
- akustikrausch/airplay2-sender-cpp README: "a working, verified AirPlay 2 realtime-audio SENDER in c++… you can find a hundred *receivers*… you cannot find a small c++ thing that just **sends** AirPlay 2 realtime audio to a current apple device" — [airplay2-sender-cpp](https://github.com/akustikrausch/airplay2-sender-cpp). Audio only.
- shairport-sync is "an AirPlay audio player" (receiver, audio only) — [shairport-sync](https://github.com/mikebrady/shairport-sync). AirConnect is audio-only bridging — [AirConnect](https://github.com/philippe44/AirConnect). UxPlay is a mirror/audio/HLS receiver — [UxPlay](https://github.com/FDH2/UxPlay). openairplay/airplay2-receiver implements "Receiving of both REALTIME and BUFFERED Airplay2 audio streams" — audio only — [airplay2-receiver](https://github.com/openairplay/airplay2-receiver).
- xfirefly/Airplay-SDK (4013 stars) distributes closed-source binaries and states "出售 AirPlay 协议源代码" (sells AirPlay protocol source code) — a commercial claim, not verifiable open code — [Airplay-SDK](https://github.com/xfirefly/Airplay-SDK).

### Inferences
- "Who has solved the hard parts": FairPlay SAP auth + SRP pairing (doubletake, airplay2-sender-cpp, airplay2-rs, objevovat/fairplay-sap-*), encrypted RAOP/RTSP audio (airplay2-sender-cpp, owntone, pyatv), mirroring video encode+encrypt (doubletake, UxPlay on the receive side). The unsolved part in the open world is **non-mirroring video streaming from a sender** (pushing a video stream, not a URL, to an Apple TV) — that path exists publicly only inside Apple's own AVPlayer/AVFoundation.

### Gaps
- Whether AirCiller (0 stars, 2026-10-15) genuinely implements an AirPlay 2 video sender in Swift on macOS or wraps AVFoundation — not verified (brand new repo; code search not conclusive in this pass).

## Key Question 2 — Does any iOS project hand a non-AVPlayer pipeline to AirPlay?

### Takeaway
No. The most convincing public evidence is negative and recent: a 2026-09 field report with logs shows a custom FFmpeg/VideoToolbox pipeline on iOS 27 delivers audio to the AirPlay receiver (via `AVSampleBufferAudioRenderer` following the audio-session route) while the picture stays in a local `AVSampleBufferDisplayLayer` — "audio-and-no-video is the guaranteed outcome of a software-path session on a wireless receiver, not a failure mode." A 2023 demo repo testing Apple's iOS 17 `AVSampleBufferVideoRenderer` reached the same conclusion: "Unfortunately at this time it (still) doesn't appear possible to achieve this."

### Cited Findings
- AetherEngine issue #550 (iPhone 17 Pro, iOS 27.0, MKV to AirPlay receiver): "The AirPlay video path… is an AVPlayer feature end to end… The software path has no AVPlayer. Its audio reaches the receiver because `AVSampleBufferAudioRenderer` follows the audio session route, and its picture goes into a local `AVSampleBufferDisplayLayer`, which AirPlay does not carry (only screen mirroring would). So audio-and-no-video is the guaranteed outcome of a software-path session on a wireless receiver, not a failure mode." — [AetherEngine #550](https://github.com/superuser404notfound/AetherEngine/issues/550) (filed 2026-09, closed 2026-09-22; fix shipped in 7.6.0).
- ryanecrist/airplay-video-demo (Swift, 1 star, pushed 2023-10-04): "Experimenting with Apple's new `AVSampleBufferVideoRenderer` API (released iOS 17) to see if it offers similar AirPlay support to its audio counterpart… Unfortunately at this time it (still) doesn't appear possible to achieve this." — [airplay-video-demo](https://github.com/ryanecrist/airplay-video-demo), referencing [Apple Forums thread 734581](https://developer.apple.com/forums/thread/734581) (page itself is behind a bot check; could not quote directly).
- KSPlayer (FFmpeg/Metal-based iOS player) issue #478 "Metal Airplay Video only cast audio": owner kingslay replied "不支持的，AirplayView只有avplayer才能进行视频播放" ("Not supported — only AVPlayer can do video playback to AirPlay") — [KSPlayer #478](https://github.com/kingslay/KSPlayer/issues/478) (2023-06).
- KSPlayer issue #437 "Airplay video with KSME?": owner: "不行，苹果只允许AVPlay进行Airplay video。但是也可以破解Airplay，把它用于KSME。但是这个工作量很多。而且apple可能会拒绝应用上架。" ("No — Apple only allows AVPlayer to do AirPlay video. You could crack AirPlay and use it for KSME, but that's a lot of work and Apple might reject the app.") — [KSPlayer #437](https://github.com/kingslay/KSPlayer/issues/437) (2023-05).
- Twilio video-quickstart-ios #473 "Cast room through AirPlay": a developer tried ReplayKit → CMSampleBuffer → AVSampleBufferDisplayLayer → AirPlay for a WebRTC room; Twilio's answer was that the only realistic routes are AirPlay **mirroring** or packaging frames into a streamable AVAsset (LL-HLS) for AVPlayer; the issue closed with no working solution — [twilio/video-quickstart-ios #473](https://github.com/twilio/video-quickstart-ios/issues/473) (2020).
- VLC for iOS: users report AirPlay yields audio-only ("With Airplay only the sound is supported for now… You can use screen mirroring") — [r/VLC thread](https://www.reddit.com/r/VLC/comments/uaq622/vlc_iphone_app_not_working_for_airplay/) (2022); vlc-ios repo has no open AirPlay-video issues (search returned none).

### Inferences
- The pattern is consistent across independent teams (AetherEngine 2026, KSPlayer 2023, ryanecrist 2023, Twilio 2020, VLC users 2022): on iOS, AirPlay **video** is only available to AVPlayer (or AVPlayerViewController/AVKit) or via whole-screen mirroring. Every custom renderer (Metal, AVSampleBufferDisplayLayer, CVPixelBuffer pipelines) gets audio at best, because `AVSampleBufferAudioRenderer` follows the audio session route while no public API routes a sample-buffer video stream to AirPlay.

### Gaps
- Apple Forums thread 734581 could not be fetched (security verification page); its content is only known via the airplay-video-demo README's summary.
- No public evidence found of anyone attempting the private-API route on iOS (KSPlayer's owner mentions it only to dismiss it).

## Key Question 3 — What do the biggest/newest repos say about AirPlay 2 vs AirPlay 1 for third parties?

### Takeaway
AirPlay 1 (RAOP) audio is fully understood and widely implemented; AirPlay 2 **audio** send/receive was cracked (FairPlay SAP handshake, SRP-6a, ChaCha20-Poly1305) and multiple working senders/receivers exist as of 2025-2026; AirPlay 2 **video** remains unimplemented by any third party — even pyatv's video support is the old AirPlay 1-style `play_url` mechanism, and it is breaking on tvOS 26.

### Cited Findings
- airplay2-sender-cpp README: "AirConnect / raop_play / the old shairport 'client' forks do AirPlay **1** / legacy rtsp. they do not do the AP2 handshake a 2024 apple tv demands (encrypted control channel, the event-channel + RECORD ordering, the hardcoded-ALAC realtime stream, the 30-second keep-alive). apple never documented any of it." — [airplay2-sender-cpp](https://github.com/akustikrausch/airplay2-sender-cpp).
- openairplay/airplay2-receiver implements FairPlay v3, HomeKit pairing, AirPlay 2 realtime+buffered **audio**; "It may never implement: MFi Authentication (requires MFi hardware module)" — [airplay2-receiver](https://github.com/openairplay/airplay2-receiver).
- energee/node-appletv-remote issue #38 (2026-10-15): "`AirPlayPlaybackSession.playUrl` fails on both Apple TVs I tested (tvOS 26.6, `AirTunes/960.13.1`). The TV accepts `POST /play` with a 200, but the first `GET /playback-info` returns `500 Internal Server Error`… pyatv 0.18.0 fails the same way" — [node-appletv-remote #38](https://github.com/energee/node-appletv-remote/issues/38). Third-party URL-push video is regressing on current tvOS.
- owntone-server README: plays "audio sources… to AirPlay 1 and 2 receivers" — audio only — [owntone-server](https://github.com/owntone/owntone-server). An owntone issue "AirPlay to HomePod OS 27 not working" was closed 2026-10-15, showing the moving-target nature of AP2 — [owntone issues](https://github.com/owntone/owntone-server/issues).
- Emanuele Cozzi's AirPlay 2 internals doc: "AirPlay 2 is a family of protocols to stream media contents including audio, videos, photos or screens. However, my main focus is on the audio part." — [emanuelecozzi.net/docs/airplay2](https://emanuelecozzi.net/docs/airplay2).

### Inferences
- The reverse-engineering community's frontier is audio. Video over AirPlay 2 (the protocol Apple TV 4K/HomePod-era devices use with iOS) has no public third-party sender implementation; even the URL-push legacy path is degrading on tvOS 26.

### Gaps
- Exact tvOS version at which `play_url` broke, and whether a workaround exists — issue #38 was closed 2026-10-15 but the resolution text was not fully captured.

## Key Question 4 — Expo/React Native/Flutter/Unity plugins claiming AirPlay video — do they use AVPlayer under the hood?

### Takeaway
Yes — every plugin found is either a thin wrapper over AVRoutePickerView/AVPlayer or explicitly says it uses native AVPlayer. None implements a non-AVPlayer video path.

### Cited Findings
- MrJai/flutter_to_airplay (38 stars, Dart, pushed 2025-09-23): "Flutter plugin that offers two widgets, one to play a video for a given URL or file path using **native AVPlayer** and second with an option to airplay it" — [flutter_to_airplay](https://github.com/MrJai/flutter_to_airplay).
- tien/react-airplay (46 stars, TS, pushed 2026-06-18): exposes `AirplayButton`, `showRoutePicker`, `useExternalPlaybackAvailability` — i.e. AVRoutePickerView + AVRouteDetector bridging; it provides the route UI, not a video pipeline — [react-airplay](https://github.com/tien/react-airplay).
- gazedash/react-native-airplay-ios (19 stars, Obj-C, pushed 2021-05-10): "An airplay button with availability and connection listeners" — UI wrapper only — [react-native-airplay-ios](https://github.com/gazedash/react-native-airplay-ios).
- `gh search code "AVRoutePickerView"` (25 results) returned only SDK bindings/headers (Xamarin, Rust objc2, runtime-header dumps, docs mirrors) and one real player integration, SRGSSR/srgmediaplayer-apple — which is an AVPlayer-based media player library — confirming AVRoutePickerView usage is always adjacent to AVPlayer — [srgmediaplayer-apple](https://github.com/SRGSSR/srgmediaplayer-apple).
- No Unity plugin claiming AirPlay video was found in any search.

### Inferences
- Cross-platform frameworks inherit the iOS limitation: since they all sit on AVPlayer (or just show the route picker), none can AirPlay video from a custom (e.g. FFmpeg) decode pipeline.

### Gaps
- Expo's own `expo-video` was not deeply inspected; it is documented as an AVPlayer-backed component, so it falls in the "uses AVPlayer" bucket by design.

## Key Question 5 — Did anyone solve IPTV or live TS to an Apple TV without AVPlayer?

### Takeaway
No. The one repo that explicitly targets IPTV to Apple TV (airthrow) does it **with AVPlayer** on macOS, and the one iOS engine with a software (non-AVPlayer) path for forward-only live streams documents that AirPlay then carries audio only.

### Cited Findings
- marcocosta97/airthrow README: "AirThrow sends video links and local files to Apple TV and other video-capable AirPlay receivers… **IPTV and Xtream** *(experimental)* — channel playlists, plus Xtream live TV, films and series." Its `PlaybackController.swift` declares `let player: AVPlayer`, uses `allowsExternalPlayback` and `AVRoutePickerView` (19 AVPlayer references across the repo) — [airthrow](https://github.com/marcocosta97/airthrow). macOS-only, 1 star, pushed 2026-10-15.
- AetherEngine #550 covers exactly the live/forward-only stream case: a non-seekable source forced the software path, and "a wireless receiver gets the sound, and screen mirroring is what carries the picture" — [AetherEngine #550](https://github.com/superuser404notfound/AetherEngine/issues/550).
- KSPlayer (the most prominent FFmpeg-based iOS/tvOS player, which handles IPTV/TS) — owner states AirPlay video requires AVPlayer; the KSME (custom) engine cannot do it — [KSPlayer #437](https://github.com/kingslay/KSPlayer/issues/437), [#478](https://github.com/kingslay/KSPlayer/issues/478).

### Inferences
- The practical pattern for IPTV apps is: hand the HLS/TS **URL** to an AVPlayer instance (or remux to HLS and hand that over) and let AVPlayer do AirPlay — which is what airthrow and AetherEngine's "native path" both do. Nobody pushes decoded live frames to Apple TV without AVPlayer.

### Gaps
- Whether any jailbreak/private-entitlement iOS app does this — not discoverable via public GitHub search.

## Key Question 6 — Reverse-engineered AirPlay senders (Python/Go/etc.) — do any work from iOS?

### Takeaway
No reverse-engineered sender runs on iOS. All verified ones are desktop/server (Linux/Windows/macOS) or Android; the iOS-relevant one (AirAP) is a receiver, and the pairing/auth building blocks (AirPlayAuth, FairPlay SAP reimplementations) are JVM/Go/Rust libraries that have never been packaged into an iOS app.

### Cited Findings
- openairplay/AirPlayAuth (Java, 97 stars, last push 2017-05-26): "This library allows to pair with an AppleTV and can be used in any app supporting streaming/casting to an AppleTV." README ends with "MORE INFORMATION FOLLOWS!" — abandoned — [AirPlayAuth](https://github.com/openairplay/AirPlayAuth).
- openairplay/ap2-sender (Obj-C, 39 stars, last push 2020-09-17): README contains only acknowledgements (airplay2-receiver, openssl, csrp, curve25519, ed25519, chachapoly) — no usage, no evidence of a working stream — [ap2-sender](https://github.com/openairplay/ap2-sender).
- objevovat/fairplay-sap-* (Go/Rust/C/C#/Kotlin/Python reimplementations of the FairPlay SAP handshake, pushed 2026-08-03): "Replaces the Apple binary and ARM64 emulator behind POST /fp-setup with ~500 KB of portable code" — auth building block only, no streaming — [libraries.io listing](https://libraries.io/go/github.com%2Fobjevovat%2Ffairplay-sap-core-airplay2-sender-authentication-handshake).
- doubletake (Go) is Linux-only (X11/Wayland/PipeWire capture) — [doubletake](https://github.com/omarroth/doubletake). airplay2-sender-cpp ships in a Windows product — [airplay2-sender-cpp](https://github.com/akustikrausch/airplay2-sender-cpp). pyatv is Python/desktop — [pyatv](https://github.com/postlund/pyatv).
- neon443/AirAP (Swift, iOS, 412 stars, pushed 2026-10-15) is "a fully native AirPlay server… use your iPhone as an AirPlay receiver" for **audio** — the opposite direction, and audio-only — [AirAP](https://github.com/neon443/AirAP).
- itsHenry35/Kite (Kotlin, 8 stars, 2026-10-11) is an **Android** AirPlay mirroring sender — Android-only — [Kite](https://github.com/itsHenry35/Kite).

### Inferences
- Nothing stops the auth/pairing code from being ported to iOS in principle, but no public project has done it, and KSPlayer's owner notes App Store rejection risk for a "cracked" AirPlay path — a strong disincentive.

### Gaps
- Whether doubletake's Go code (or the FairPlay SAP whitebox) could compile for iOS — untested by anyone publicly.

## What remains unverified

- **AirCiller** (Swift, macOS, 0 stars, created ~2026-10): claims AirPlay 2 video with HDR/Dolby Vision from a Mac — could be a genuine protocol-level sender or an AVFoundation wrapper; needs code inspection to classify.
- **airkast** (Kotlin, 0 stars): URL-push video to LG webOS TV claimed tested on exactly one TV; no independent verification.
- **xfirefly/Airplay-SDK**: commercial, closed-source; its mirroring/casting claims cannot be validated from the repo (binaries + sales pitch only).
- Apple Forums thread 734581 (the canonical "AVSampleBufferVideoRenderer + AirPlay" question) — content not directly fetched (bot wall).
- The resolution of the tvOS 26 `play_url` breakage (node-appletv-remote #38) — whether third-party URL-push video still works at all on current tvOS.
- `gh search issues "airplay video not working"` returned zero results (query too literal); broader issue searches ("airplay video", "airplay") were used instead and are what the issue findings above draw from.
