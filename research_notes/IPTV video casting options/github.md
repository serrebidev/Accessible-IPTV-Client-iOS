# GitHub libraries for iOS IPTV video sending

## Which projects are newest and which have the most stars?

### Takeaway
Two separate rankings below cover the relevant shortlisted building blocks, not every search hit. The newest promising full Apple player is AetherEngine; the strongest current transcoding building block is the official FFmpegKitNext continuation. Neither is a universal AirPlay-and-Chromecast sender by itself. [AetherEngine](https://github.com/superuser404notfound/AetherEngine), [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next)

### Cited Findings
GitHub REST API observations taken 2026-10-15 America/Vancouver. Dates below are `pushed_at` in UTC; push activity is not proof of a recent release or working feature. Queries used `search/repositories` separately with `sort=updated&order=desc` and `sort=stars&order=desc`: `airplay video ios`, `IPTV airplay`, `chromecast ios video`, `KSPlayer`, `media_kit`, `ffmpeg hls ios`, `airplay language:Swift`, `chromecast language:Swift`, `IPTV iOS`, and narrower variants. Search updated ordering is not strictly push ordering, so the curated newest table is explicitly sorted by actual `pushed_at`. [GitHub API search documentation](https://docs.github.com/en/rest/search/search#search-repositories)

Newest pushes, relevant shortlist:

| Project | Stars | Last push UTC | Archived | License/API metadata | Role |
|---|---:|---|---|---|---|
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | 238 | 2026-10-15 22:11:19 | No | API NOASSERTION; README LGPL-3.0 with store exception | FFmpeg remux/local playback/native AirPlay video subset |
| [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer) | 19 | 2026-10-15 21:37:46 | No | LGPL-3.0 | Example app using AetherEngine |
| [airthrow](https://github.com/marcocosta97/airthrow) | 1 | 2026-10-15 20:57:48 | No | Apache-2.0 | macOS AirPlay sender with external FFmpeg conversion |
| [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) | 163 | 2026-10-15 14:38:10 | No | LGPL-3.0 default; GPL if GPL components enabled | Current FFmpeg execution/transcoding library |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | 6 | 2026-10-12 09:40:34 | No | LGPL-2.1 | AetherEngine binary dependencies; video decoders, not video encoders |
| [KSPlayer](https://github.com/kingslay/KSPlayer) | 1,680 | 2026-10-10 13:57:38 | No | GPL-3.0; paid LGPL option | AVPlayer/FFmpeg/MPV playback framework |
| [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit) | 229 | 2026-10-07 17:10:30 | No | GPL-3.0; paid LGPL option | Packaged Apple FFmpeg command execution |
| [crispy-tivi](https://github.com/moabualruz/crispy-tivi) | 27 | 2026-09-30 06:15:56 | No | API NOASSERTION; README CC BY-NC-SA 4.0 | Flutter/Rust IPTV app; separate limited senders |
| [SwiftCast](https://github.com/CreatureSurvive/SwiftCast) | 0 | 2026-09-27 17:29:08 | No | MIT | Pure Swift Cast V2 sender, no conversion |
| [HLSRemuxKit](https://github.com/oustn/HLSRemuxKit) | 0 | 2026-08-31 13:56:57 | No | No repository license detected | iOS lossless HLS remux only |
| [media-kit](https://github.com/media-kit/media-kit) | 1,842 | 2026-08-30 17:32:28 | No | MIT for wrapper; libmpv dependencies separate | Flutter/Dart local player |
| [Connect-SDK-iOS](https://github.com/ConnectSDK/Connect-SDK-iOS) | 193 | 2026-03-03 10:51:02 | No | Apache-2.0 | Multi-device control SDK; not universal transcoder |
| [CastVideos-ios](https://github.com/googlecast/CastVideos-ios) | 211 | 2024-04-29 08:06:18 | Yes | Apache-2.0 for sample; Google SDK terms separate | Official Cast video sender example |
| [OpenCastSwift](https://github.com/mhmiles/OpenCastSwift) | 129 | 2019-07-07 22:29:26 | No | MIT | Older Cast sender, no conversion |

Highest stars, same shortlist plus historical upstream:

| Rank | Project | Stars | Last push UTC date | Archived |
|---|---|---:|---|---|
| 1 | [Original FFmpegKit](https://github.com/arthenica/ffmpeg-kit) | 5,851 | 2026-07-02 | Yes |
| 2 | [media-kit](https://github.com/media-kit/media-kit) | 1,842 | 2026-08-30 | No |
| 3 | [KSPlayer](https://github.com/kingslay/KSPlayer) | 1,680 | 2026-10-10 | No |
| 4 | [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | 238 | 2026-10-15 | No |
| 5 | [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit) | 229 | 2026-10-07 | No |
| 6 | [CastVideos-ios](https://github.com/googlecast/CastVideos-ios) | 211 | 2024-04-29 | Yes |
| 7 | [Connect-SDK-iOS](https://github.com/ConnectSDK/Connect-SDK-iOS) | 193 | 2026-03-03 | No |
| 8 | [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) | 163 | 2026-10-15 | No |
| 9 | [OpenCastSwift](https://github.com/mhmiles/OpenCastSwift) | 129 | 2019-07-07 | No |
| 10 | [crispy-tivi](https://github.com/moabualruz/crispy-tivi) | 27 | 2026-09-30 | No |
| 11 | [AetherPlayer](https://github.com/superuser404notfound/AetherPlayer) | 19 | 2026-10-15 | No |
| 12 | [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) | 6 | 2026-10-12 | No |
| 13 | [airthrow](https://github.com/marcocosta97/airthrow) | 1 | 2026-10-15 | No |
| 14 | [SwiftCast](https://github.com/CreatureSurvive/SwiftCast), [HLSRemuxKit](https://github.com/oustn/HLSRemuxKit) | 0 each | 2026-09-27 / 2026-08-31 | No |

- Original FFmpegKit explicitly says it is retired and FFmpegKitNext is maintained by its original author. Do not mistake its July 2026 push for resumed original-project development. [Original README](https://github.com/arthenica/ffmpeg-kit#update-july-2026)
- Excluded receiver-only search hits: AirPlayServer, ender-airplay-streamer, AirAP, android receiver projects. Excluded audio-only hits: AirPlay-Enabler, iOS-Audio-to-ChromeCast. Excluded merely wrapping AVPlayer as an all-format answer: VersaPlayer and EZPlayer. Their descriptions/source declare their actual purpose. [AirPlayServer](https://github.com/xenos1337/AirPlayServer), [ender-airplay-streamer](https://github.com/EnderTheCoder/ender-airplay-streamer), [AirPlay-Enabler](https://github.com/Optimus-Player/AirPlay-Enabler), [VersaPlayer](https://github.com/josejuanqm/VersaPlayer), [EZPlayer](https://github.com/easyui/EZPlayer)

### Inferences
- Star count cannot substitute for sender-video capability: the largest relevant player frameworks do not supply universal wireless video conversion. The tables rank components and reference apps, not interchangeable complete solutions.

### Gaps
- Search is a curated GitHub survey, not an exhaustive census. No runtime tests on iPhone, Apple TV, Chromecast, or actual provider credentials were performed.

## Do the finalists actually send video from arbitrary IPTV formats?

### Takeaway
No verified ready-made GitHub dependency met all of: iOS17/tvOS17/visionOS1, arbitrary IPTV input, AirPlay video, Chromecast video, and no external server. Receiver control, local broad-codec playback, and transcoding are distinct capabilities. [Aether API](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/api.md), [SwiftCast README](https://github.com/CreatureSurvive/SwiftCast), [media-kit maintainer explanation](https://github.com/media-kit/media-kit/issues/721#issuecomment-1977223540)

### Cited Findings
- **AetherEngine is technically relevant, not an AVPlayer wrapper alone.** It demuxes using FFmpeg, stream-copies acceptable video into HLS-fMP4, bridges incompatible audio, and feeds AVPlayer. Its internal HLS server binds all interfaces with a per-session token; AirPlay changes the playback host from 127.0.0.1 to a LAN IP because a receiver cannot fetch the phone's loopback address. [HLSLocalServer source](https://github.com/superuser404notfound/AetherEngine/blob/main/Sources/AetherEngine/Network/HLSLocalServer.swift), [AirPlayPlaylistDecision source](https://github.com/superuser404notfound/AetherEngine/blob/main/Sources/AetherEngine/Native/AirPlayPlaylistDecision.swift)
- **AetherEngine does not solve all-codec AirPlay video.** Its public `$airPlayPictureStaysLocal` explicitly reports audio-only AirPlay when software rendering handles VP9, AV1 without suitable hardware, MPEG-2, VC-1, or deinterlaced H.264. `$currentAVPlayer` is nil on that route. [Public API, session state](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/api.md#what-the-session-is-doing), [format routes](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/formats.md)
- **AetherEngine platform mismatch:** current package requires iOS18, tvOS18, macOS15, visionOS1 and Swift tools6.1. That raises this app's iOS/tvOS floors if integrated directly. [Package.swift](https://github.com/superuser404notfound/AetherEngine/blob/main/Package.swift)
- **AetherEngine licensing:** LGPL3 with explicit Apple Store/DRM exception for engine code; dynamic FFmpeg dependency is plain LGPL2.1+, no GPL components. Extra default traits bring object-audio decoder dependencies. [License section](https://github.com/superuser404notfound/AetherEngine#license), [Package.swift](https://github.com/superuser404notfound/AetherEngine/blob/main/Package.swift)
- **AetherEngine's FFmpegBuild is not a video-transcode solution:** encoders are removed except FLAC/EAC3 for audio bridging. No corresponding video encoding API was found. [FFmpegBuild README](https://github.com/superuser404notfound/FFmpegBuild)
- **KSPlayer:** broad local decoding and a SwiftUI `AirPlayView` which is an AVRoutePickerView. Historical maintainer issue explains that FFmpeg rendering does not gain AVPlayer video sending; MKV demux-to-AVPlayer and external-display mirroring were discussed as different solutions. README currently has paid native AVPlayer MKV features and GPL default, so do not infer free all-codec sending. [AirPlayView source](https://github.com/kingslay/KSPlayer/blob/main/Sources/KSPlayerUI/SwiftUI/AirPlayView.swift), [issue645](https://github.com/kingslay/KSPlayer/issues/645), [licensing/current feature list](https://github.com/kingslay/KSPlayer)
- **media-kit:** libmpv player for Flutter/Dart; maintainer explicitly says casts belong in a separate package. Reports describe audio-only AirPlay, and maintainer explained why libmpv rendering lacks AVPlayer integration. Changing this native SwiftUI app to media-kit would not supply the missing conversion. [Issue207](https://github.com/media-kit/media-kit/issues/207#issuecomment-1616187748), [issue721](https://github.com/media-kit/media-kit/issues/721#issuecomment-1977223540), [architecture](https://github.com/media-kit/media-kit#architecture)
- **crispy-tivi:** despite advertising both senders and broad libmpv playback, iOS AirPlay creates `AVPlayerItem(url:)` directly; Cast sends a LOAD with the input URL. No transcoding bridge is established by those paths. License is CC BY-NC-SA4.0 according to README, not permissive source. [AirPlayPlugin](https://github.com/moabualruz/crispy-tivi/blob/main/app/flutter/ios/Runner/AirPlayPlugin.swift), [CastHelper](https://github.com/moabualruz/crispy-tivi/blob/main/app/flutter/lib/features/casting/data/cast_helper_io.dart), [README](https://github.com/moabualruz/crispy-tivi)
- **Ondo IPTV** (new zero-star iOS app, MIT) is unusually explicit: Google Cast receiver fetches the URL; custom headers are lost; TS/MKV/AVI inputs are rejected by its castability gate. It creates `GCKMediaInformationBuilder(contentURL:)` and calls `client.loadMedia`. This is an implementation example of the exact limitation, not a solution. [CastManager.swift](https://github.com/markedoe/ondo-iptv/blob/main/App/Player/CastManager.swift)
- **SwiftCast:** real video-capable pure-Swift Google Cast sender for iOS/iPadOS/macOS/tvOS/visionOS. README uses HLS and MP4 LOAD examples; implements discovery, session/media controls and live streams. Reports testing discovery/load/seek/pause on an onn4K Google TV device. It is a sender only, no screen mirroring and no transcoding. [README](https://github.com/CreatureSurvive/SwiftCast), [media controller](https://github.com/CreatureSurvive/SwiftCast/blob/main/Sources/SwiftCast/Client/MediaController.swift)
- **airthrow:** useful architecture reference, but macOS app, not iOS library. Supports remuxing compatible video and reencoding unsupported audio/video using external FFmpeg; README distinguishes direct/remux/reencode/WIP/incompatible formats. Requires Mac tools and does not prove live all-format iOS operation. [README](https://github.com/marcocosta97/airthrow)
- **HLSRemuxKit:** iOS16 arm64 device/arm64 simulator, lossless remux only. Explicitly does not decode or reencode. No x86_64 slices, no demonstrated tvOS/visionOS product, and no repository-level license detected; avoid adopting blindly. [README](https://github.com/oustn/HLSRemuxKit)

### Inferences
- AetherEngine could remux many raw `.ts` inputs containing compatible progressive H264/HEVC without rewriting the provider URL, but cannot promise video for MPEG2/interlaced/unsupported receiver codecs. Its HLS server and URLs are internal, so exporting its remux stream to Cast would need a fork or new stable public API; reading currentAVPlayerItem.asset URL alone is not a verified lifecycle API.
- Codec compatibility belongs to the receiving TV as well as the phone. A phone capable of locally decoding a stream does not make that stream castable without conversion.

### Gaps
- No tested full-format AirPlay sender package found. KSPlayer paid features were not purchased or tested. No branch was compiled for real Apple hardware.

## What should this app actually adopt?

### Takeaway
For the stated all-format goal, prefer **FFmpegKitNext as the conversion engine**, preserving VLCKit for existing local playback; add one shared on-device HLS output service, consume it through native AVPlayer for AirPlay and a Cast sender for Chromecast. This is an engineering recommendation, not a claim that a single library finishes the feature. [FFmpegKitNext Apple documentation](https://github.com/arthenica/ffmpeg-kit-next/tree/main/apple), [official Cast sender example](https://github.com/googlecast/CastVideos-ios)

### Cited Findings
- FFmpegKitNext is the original author's official continuation and supports native iOS/iPadOS/tvOS/visionOS. Default LGPL3, GPL only when GPL components are enabled. Its Apple API executes FFmpeg commands. [Main README](https://github.com/arthenica/ffmpeg-kit-next), [retired upstream redirect](https://github.com/arthenica/ffmpeg-kit#update-july-2026)
- Apple target floors fit the existing app: iOS12.1+, tvOS11+, visionOS1+. It supports dynamic frameworks/xcframeworks and can generate local Swift package manifests. Apple build requires macOS/Xcode26+, Nix recommended but optional. [Apple build and feature docs](https://github.com/arthenica/ffmpeg-kit-next/tree/main/apple)
- **Source-only distribution:** official FFmpegKitNext does not publish binaries. Latest v9.0.0 release has no attached assets. Build the required Apple slices and host/embed artifacts; adding the Git URL to Xcode is insufficient because the native Package.swift is generated beside build outputs. [Apple documentation](https://github.com/arthenica/ffmpeg-kit-next/tree/main/apple#2-building), [releasev9.0.0](https://github.com/arthenica/ffmpeg-kit-next/releases/tag/v9.0.0)
- Concrete upstream build examples: `./nix-ios.sh -p xcode26 -x --spm`, matching `nix-tvos.sh` / `nix-visionos.sh`, then `./nix-apple.sh -p xcode26 --spm` for umbrella Apple xcframeworks. Enable platform VideoToolbox/AudioToolbox components needed by the chosen output; keep GPL libraries disabled. [Build options](https://github.com/arthenica/ffmpeg-kit-next/tree/main/apple#22-options)
- Actual ObjC API: `+[FFmpegKit executeWithArgumentsAsync:withCompleteCallback:]`; overloads accept logs/statistics and dispatch queues. `+[FFmpegKit cancel:]` takes a session id. Each returned FFmpegSession exposes its id, return code, logs, statistics, command args and failure details. Use argument-array API for URLs/headers instead of building an escaped command string. [FFmpegKit.h](https://github.com/arthenica/ffmpeg-kit-next/blob/main/apple/src/FFmpegKit.h), [Apple use examples](https://github.com/arthenica/ffmpeg-kit-next/tree/main/apple#3-using)
- A ready packaged alternative is kingslay/FFmpegKit with `ffmpeg_execute(Int32(arguments.count), &argv)` and Apple platform coverage including visionOS, but its default license is GPL and LGPL version paid. That is a material integration constraint for this MIT app. [README](https://github.com/kingslay/FFmpegKit)
- AetherEngine public integration, if app floors change for another reason: `AetherEngine()`; `bind(view: AetherPlayerView)`; `load(url:options:)` with `LoadOptions.isLive` and `httpHeaders`; observe `$currentAVPlayer`, `$airPlayPictureStaysLocal`, and live reset/failure publishers. This still requires an additional transcode fallback for the user's goal. [API docs](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/api.md)

### Inferences
- Minimal complete pipeline: fetch exact original provider URL and required headers; probe streams; stream-copy only compatible tracks; otherwise video-decode/deinterlace and encode H264 plus AAC; produce rolling HLS; serve over authenticated LAN HTTP with bounded retention; native AVPlayer/AVRoutePickerView for AirPlay video and Google Cast SDK (iOS) or SwiftCast (broader Apple sender targets) for Cast LOAD/control. The generated output URL is separate from the untouched provider `.ts` URL.
- Use official Google SDK for production iOS interoperability unless multi-platform sender support justifies a small new SwiftCast dependency. SwiftCast has zero stars and limited published hardware evidence, so its novelty is a risk despite very recent maintenance.
- True all-format coverage is bounded by the compiled FFmpeg decoders, DRM, malformed input, receiver support and phone thermal/encoding capacity. Expose specific errors rather than reporting casting connected while only audio plays. Real-time transcoding must be checked on target hardware, particularly high-resolution/interlaced IPTV.
- Do not adopt AetherEngine/KSPlayer/media-kit as a shortcut that silently downgrades video to audio; they fail the exact acceptance criterion unless paired with conversion.

### Gaps
- No binary compilation, package resolution, streaming test, license audit or receiver validation performed in this research task. Native build provisioning and existing VLCKit/FFmpeg symbol coexistence must be proved before release. Default-enabled encoder availability and actual VideoToolbox encoding performance in a chosen FFmpegKitNext build remain to be tested.
