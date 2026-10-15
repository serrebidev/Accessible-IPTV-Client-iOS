# Accessible IPTV Client for iOS - agent notes

iOS port of the Android app (serrebidev/Accessible-IPTV-Client-Android, local checkout
`../accessible IPTV client Android`). One SwiftUI target for iPhone, iPad, Apple TV and Vision Pro,
plus a CarPlay audio scene. iOS 17 / tvOS 17 / visionOS 1.

## Layout

- `Core/` - Swift package `IPTVCore`: M3U, XMLTV (own streaming XML reader over gzip chunks), catch-up,
  Xtream, Stalker, SQLite guide (`Epg`), `Library` (port of Android `App.kt`), prefs, recording loop,
  TS clock, live cushion and reconnect, subtitle cues. No UIKit. Tests in `Core/Tests` are ports of the
  Android ParsingTest/CoreTest/GuideTest/AppTest/FeatureTest.
- `App/` - SwiftUI screens (one per Android activity), `PlayerController` (libVLC via VLCKit 4),
  `RecorderCenter`, `CarPlay.swift`, `VoiceSearch`.
- `Resources/<lang>.lproj` - generated. `tools/android_strings.py` converts the Android strings.xml
  (14 languages) and holds the iOS-only strings; `tools/build_help.py` builds help.md from the Android
  help with iOS paragraphs. A new user-facing string goes into `EXTRA` with all 14 languages.
  Hungarian uses the desktop translator's terms (műsorújság, rögzítés, importálás). Typographic ’ only.
- `project.yml` - XcodeGen; the .xcodeproj is not committed.

## Test

- Windows: `swift test` in `Core` runs everything except SQLite and gzip (Swift 6.4 toolchain via winget
  Swift.Toolchain; set PATH to Toolchains/6.4.1+Asserts/usr/bin and Runtimes/6.4.1/usr/bin, SDKROOT to the
  Windows.sdk). macOS CI runs all of it.
- The app itself only builds on macOS: push and read the Build workflow.

## Rules

- Player is libVLC (VLCKit 4.0.0-a22 from code.videolan.org SPM): AVPlayer cannot play raw MPEG-TS,
  which is what Xtream live URLs are. Live URLs stay `.ts` (Dispatcharr answers `.m3u8` with 500).
- libVLC never hands over subtitle text: embedded subtitles are drawn in the picture; only a loaded
  SRT/WebVTT file is spoken (same limit as the desktop).
- Live cushion = desktop's VLC method: `media.statistics` read vs demux bytes, rate 0.95 until the
  cushion is held (`Cushion` in Playback.swift).
- Background: UIBackgroundModes audio. Playback continues with the screen locked (video track off).
  Recording keeps the app awake with a silent looping sound while recording or a schedule is within 6 h;
  otherwise a local notification at start time asks to open the app. iOS cannot wake an app on time.
- tvOS: data and recordings live in Caches (no persistent storage); no file picker, voice or notifications.
- Accessibility: follow cvs-health/ios-swiftui-accessibility-techniques. Rows are one element
  (`.row(speech, actions:)`): VoiceOver custom actions + context menu, never per-row buttons. Headings via
  `.heading()`. Status changes go through `announce()`. Errors: text under the field, VoiceOver focus moved
  there, error announced. Blunt wording, explanations in Help.
- Settings keys and JSON shapes match the Android app, so its export imports here.
- SharePlay (0.3.0+): only `WatchTVActivity.relayHost` opens the provider. A second VLC instance remuxes it
  (`#std{access=http,mux=ts}` on loopback, Basic auth) into `RelayBuffer`; `RelayServer` (loopback NWListener)
  feeds local VLC; `RelayHost` puts 2 s whole-packet chunks in `GroupSessionJournal` and announces them
  (`RelayWindow`, SHA-256) over the messenger. Guests verify and never touch the provider. No server.
  `relayHost` nil = v0.2.0 per-device path. `tools/shareplay-probe` (its own workflow) validates the VLC remux;
  journal throughput is unmeasured on real devices.
- Siri: phrase parameters match only `suggestedEntities` (100); Spotlight `IndexedEntity` (iOS 18+, 1000).
  AltStore re-signs as `<bundle id>.<team id>`; the IPA's Metadata.appintents still carries the original id.

## Release

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in project.yml, add a `## X.Y.Z` section to
   CHANGELOG.md, commit, tag `vX.Y.Z`, push with the tag.
   Builds are signed with the owner's AltStore Apple Development certificate (team J7645K945T) from repo
   secrets IOS_SIGNING_P12 / IOS_SIGNING_P12_PASSWORD. Preserve `App/AccessibleIPTV.entitlements` when
   signing: SharePlay needs `com.apple.developer.group-session`, including in the installation profile.
   AltStore's source must list this entitlement. No secrets (fork PR) = unsigned build.
2. The Build workflow (macos runner) publishes `AccessibleIPTV-X.Y.Z-{iOS,tvOS,visionOS}.ipa` to the release.
3. In `../serrebiALT`: `python add_app.py AccessibleIPTV-X.Y.Z-iOS.ipa --url <release asset url> --notes "..."`,
   commit and push apps.json. AltStore re-signs the .ipa with the user’s own profile on install.
