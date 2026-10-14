# Accessible IPTV Client for iOS

A vibe-coded, screen-reader-friendly IPTV player for iPhone, iPad, Apple TV and Apple Vision Pro, with CarPlay audio. Built for VoiceOver, and to handle big playlists and guides without choking.

[![Join SerrebiProjects on Telegram](https://img.shields.io/badge/Telegram-SerrebiProjects-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/SerrebiProjects)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

This is the iOS port of [Accessible IPTV Client for Android](https://github.com/serrebidev/Accessible-IPTV-Client-Android), the companion to [Accessible IPTV Client](https://github.com/serrebidev/Accessible-IPTV-Client) for Windows and Linux.

## Features

- Xtream Codes logins, Stalker portals (address and MAC), M3U / M3U Plus playlist URLs, and M3U files picked in the Files app.
- Live TV, Movies and Series, each with groups plus Favourites and All at the top. A series opens to its episodes, in season order.
- Search at the top covers every group in the section, with a Voice button that fills it by speech.
- XMLTV guide (`.xml` and `.xml.gz`), including large guides, read as it downloads. Each channel says what is on and until when; On Now lists everything airing; Guide search finds upcoming programmes.
- Catch-up playback for channels with an archive (Xtream timeshift and M3U catch-up templates, the desktop rules).
- Built-in player (libVLC) that plays raw MPEG-TS, HLS, MKV and MP4, with always-visible controls and a full screen mode. It picks an audio description track when a channel has one and remembers a track you choose per channel.
- Live playback starts with half a second buffered, then builds a 25-second cushion during playback, like the desktop app. A dropped live stream reconnects by itself. Sound keeps playing with the screen locked.
- Casts to Chromecast, or hands a stream to VLC, Infuse, nPlayer or Outplayer.
- Record now, schedule recordings from the guide, and download movies, episodes and catch-up programmes. Recordings appear in the Files app.
- Previous channel, Recently watched, Go to channel number; number keys on a keyboard jump straight to a channel.
- Export and import every setting, playlist and favourite as one file, including a file exported from the Android app.
- 14 languages: English, Spanish, Arabic, Portuguese (Brazilian), French, German, Russian, Turkish, Italian, Polish, Hindi, Chinese (Simplified), Japanese and Hungarian.
- CarPlay lists favourite and recently watched channels and plays their sound (needs a build signed with Apple's CarPlay audio permission).

## Accessibility

Built for VoiceOver following the [CVS Health iOS SwiftUI accessibility techniques](https://github.com/cvs-health/ios-swiftui-accessibility-techniques); every build runs their `a11y-check`.

- Every list row is one stop. Extra choices (another player, favourite, details, guide, record, download) are in the VoiceOver Actions rotor, or on touch and hold.
- Real buttons with short, plain names. No icon-only controls, no auto-hiding overlays.
- Headings on every section, labelled form fields, and errors that move VoiceOver to the field that needs fixing.
- Status changes are announced, and only when something happened. The player's announcements follow Settings, Announcements.
- A two-finger double tap plays and pauses. Dynamic Type, dark mode, every orientation.
- On Apple TV every control is reachable with the remote.

## Install

Add the serrebiALT source to AltStore:

https://raw.githubusercontent.com/serrebidev/serrebiALT/main/apps.json

then install Accessible IPTV from it. AltStore keeps it updated. The `.ipa` files for iPhone and iPad, Apple TV and Vision Pro are also on the [Releases page](https://github.com/serrebidev/Accessible-IPTV-Client-iOS/releases) for other sideloading tools. Needs iOS 17, tvOS 17 or visionOS 1 or later.

## Getting started

1. Open **Playlists** and add an Xtream login, an M3U URL, an M3U file, or a Stalker portal.
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
