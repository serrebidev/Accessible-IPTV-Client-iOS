# Accessible IPTV Client for iOS

A vibe-coded, screen-reader-friendly IPTV player for iPhone, iPad, Apple TV and Apple Vision Pro, with CarPlay audio. Built for VoiceOver, and to handle big playlists and guides without choking.

[![Join SerrebiProjects on Telegram](https://img.shields.io/badge/Telegram-SerrebiProjects-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/SerrebiProjects)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

This is the iOS port of [Accessible IPTV Client for Android](https://github.com/serrebidev/Accessible-IPTV-Client-Android), the companion to [Accessible IPTV Client](https://github.com/serrebidev/Accessible-IPTV-Client) for Windows and Linux.

## Features

- Xtream Codes logins, Stalker portals (address and MAC), M3U / M3U Plus playlist URLs, and M3U files picked in the Files app.
- Categories open first, with Favourites and All as explicit choices. Live TV, Movies and Series each have their own categories. A series opens to its episodes, in season order.
- Native iPhone and iPad tabs for Browse, Guide, Recordings and Settings, with search in the navigation bar. Playlists live in Settings, as **Sources**; with none added yet, Browse shows an **Add sources** button.
- Search at the top covers every group in the section, with a Voice button that fills it by speech.
- XMLTV guide (`.xml` and `.xml.gz`), including large guides, read as it downloads. Each channel says what is on and until when; On Now lists everything airing; Guide search finds upcoming programmes.
- Catch-up playback for channels with an archive (Xtream timeshift and M3U catch-up templates, the desktop rules).
- AVPlayer handles compatible streams, with libVLC for raw MPEG-TS, MKV and other IPTV formats. Controls remain visible, with a full screen mode. The player prefers audio description and remembers audio tracks per channel.
- Minimize the player to keep watching while browsing. The miniplayer expands back to the same stream, with separate pause and stop controls.
- Native iOS background audio with lock-screen and headset controls. Calls interrupt playback; it resumes when iOS permits, unless you paused it. Disconnecting headphones pauses playback.
- Live playback starts with half a second buffered, then builds a 25-second cushion during playback, like the desktop app. A dropped live stream reconnects by itself. Sound keeps playing with the screen locked.
- **Playback destination** is one list on iPhone and iPad: this device, AirPlay devices and Cast devices, each labelled by type. Compatible video goes through AVPlayer; other IPTV video is converted locally to H.264/AAC HLS at its source resolution, and picking an AirPlay or Cast device starts that conversion automatically. No separate server is required. Keep the app open on the receiver’s Wi-Fi while converting; choose audio and subtitles before sending. Protected content, receiver limits and device performance can limit conversion. Audio-only receivers play sound only. A stream can also be handed to VLC, Infuse, nPlayer or Outplayer.
- Record now, schedule recordings from the guide, and download movies, episodes and catch-up programmes. Recordings appear in the Files app.
- Previous channel, Recently watched, Go to channel number; number keys on a keyboard jump straight to a channel.
- Export and import every setting, source and favourite as one file, including a file exported from the Android app.
- 14 languages: English, Spanish, Arabic, Portuguese (Brazilian), French, German, Russian, Turkish, Italian, Polish, Hindi, Chinese (Simplified), Japanese and Hungarian.
- CarPlay lists favourite and recently watched channels and plays their sound (needs a build signed with Apple's CarPlay audio permission).
- On iPhone, App Intents expose channel tuning, now/next guide answers, guide search, channel-guide navigation, and pause/resume/stop to Siri and Shortcuts. Focused channel rows and the player provide onscreen entity context on iOS 18.2 or later.

## Siri and Apple Intelligence

Add a source and open the app once to import its guide. Then try:

- “Play Sky Mix in Accessible IPTV”, “Tune to Sky Mix in Accessible IPTV”, or “Watch Sky Mix in Accessible IPTV”. Channel numbers work too; Siri offers choices for ambiguous matches. Provider labels such as “UK: Sky | Mix HD” have the spoken alias “Sky Mix”.
- Add a channel to Favourites or play it once to publish its name to Siri. Every favourite and recent channel is included; favourites no longer crowd out recent channels. Allow Siri time to update its vocabulary.
- For a channel Siri does not recognise in the first request, say “Watch TV in Accessible IPTV” (or “Play TV in Accessible IPTV”, “Tune to a channel in Accessible IPTV”), then answer with its name. This searches the full live playlist.
- App Shortcut phrases require the app name. To say only “Play Sky Mix”, create a personal shortcut with the Tune channel action set to Sky Mix, then name that shortcut “Play Sky Mix”. Create separate named shortcuts for “Tune to Sky Mix” or “Watch Sky Mix” if wanted.
- “What is on BBC One in Accessible IPTV?” Reads the current and next programme from the imported guide.
- “Search the guide in Accessible IPTV.” Siri asks for the search text and reads up to five current or upcoming matches.
- “Show the guide for BBC One in Accessible IPTV.” Opens that channel’s guide while keeping existing playback in the miniplayer.
- “Pause playback in Accessible IPTV”, “Resume playback in Accessible IPTV”, or “Stop playback in Accessible IPTV”.

All seven actions also appear in Shortcuts and can be combined with its Apple Intelligence actions on supported devices. The app supplies real channel and guide data through [Apple’s App Intents framework](https://developer.apple.com/documentation/appintents/appintent). These commands also work on iPhones without Apple Intelligence. System support, language, and device determine which Apple Intelligence experiences are available. The app does not generate programme listings or send provider credentials to an AI service.

Implementation references: [Apple’s entity and intent sample](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents/), [onscreen entity context](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri), and [RetroArch’s App Intents integration on GitHub](https://github.com/libretro/RetroArch/blob/master/pkg/apple/AppIntents/RetroArchAppShortcuts.swift). No third-party AI package is required.

## SharePlay

Start a FaceTime call, play a channel or video, then choose **Start SharePlay** in the expanded player. Everyone needs the app and their own playlist and login. Channel changes, play and pause are shared; movies, numbered series episodes and catch-up programmes use native playback coordination when the source can seek. Each device resolves its own stream. The activity contains public channel metadata and archive times, never stream URLs or provider credentials. Missing or ambiguous matches show an error instead of choosing another provider's stream.

**Minimize** keeps the session playing. **Stop playback** leaves locally; **Leave SharePlay** keeps local playback, and **End for everyone** ends the shared session. Recordings, local files and Chromecast playback cannot join. Live streams share controls; different providers and buffers prevent frame-perfect live timing. VLC starts and seeks asynchronously, so seekable sources also have some timing tolerance.

The build and installation profile must retain Apple's `com.apple.developer.group-session` entitlement. The release includes that entitlement, and the AltStore source declares it. A sideloading tool must support provisioning it. References: [Apple's Group Activities setup](https://developer.apple.com/documentation/xcode/configuring-group-activities), [custom-player playback coordinator](https://developer.apple.com/documentation/avfoundation/avdelegatingplaybackcoordinator), and [an independent VLC coordinator implementation on GitHub](https://github.com/marvinvr/dusk-player/blob/main/Dusk/Sources/Playback/VLCKitEngine.swift).

## Accessibility

Built for VoiceOver following the [CVS Health iOS SwiftUI accessibility techniques](https://github.com/cvs-health/ios-swiftui-accessibility-techniques); every build runs their `a11y-check`.

- Every list row is one stop. Extra choices (another player, favourite, details, guide, record, download) are in the VoiceOver Actions rotor, or on touch and hold.
- Real buttons with short, plain names. Compact transport buttons have VoiceOver labels. No auto-hiding overlays.
- Headings on every section, labelled form fields, and errors that move VoiceOver to the field that needs fixing.
- Status changes are announced, and only when something happened. The player's announcements follow Settings, Announcements.
- A two-finger double tap plays and pauses. Dynamic Type, dark mode, every orientation.
- On Apple TV every control is reachable with the remote.

## Install

Add the serrebiALT source to AltStore:

https://raw.githubusercontent.com/serrebidev/serrebiALT/main/apps.json

then install Accessible IPTV from it. AltStore keeps it updated. The `.ipa` files for iPhone and iPad, Apple TV and Vision Pro are also on the [Releases page](https://github.com/serrebidev/Accessible-IPTV-Client-iOS/releases) for other sideloading tools. Needs iOS 17, tvOS 17 or visionOS 1 or later.

## Getting started

1. Open **Settings**, then **Sources**, and add an Xtream login, an M3U URL, an M3U file, or a Stalker portal.
2. Go back. Channels load, then the guide imports in the background.
3. Pick a group, or just search.

## Build

Needs a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
open AccessibleIPTV.xcodeproj
```

The rules (playlists, guide, catch-up, providers) are a Swift package with tests: `cd Core && swift test`.

## Contributing

Pull requests are welcome. If Accessible IPTV Client has been useful to you, open a PR with a fix or feature and I'll review it.
