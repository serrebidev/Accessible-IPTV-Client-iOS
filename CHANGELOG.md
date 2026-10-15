# Changelog

## 0.1.2

- Typing in the search field uses about a third of the CPU: the names it matches against are prepared when a list loads, instead of on every keystroke. Searching a 50,000 channel list went from 0.23 s to 0.073 s.
- A fresh launch no longer hashes every channel on the main thread to check whether the guide is still current; that is done once, in the background, while the list loads.

## 0.1.1

- Much less CPU when a guide imports: the guide reader is about 12 times faster and skips the programmes of channels you do not have without reading them. Xtream guides import in seconds instead of minutes.
- Large Xtream movie and series lists load about twice as fast.
- The channel list no longer redraws every row when the status line changes, and channel rows look up their guide entry once.
- The player stops its background timers when it does not need them, and looks up its channel once.
- Recordings no longer write to storage every 15 seconds when nothing changed.

## 0.1.0

First iOS release, a port of Accessible IPTV Client for Android 0.2.11.

- iPhone, iPad, Apple TV and Vision Pro, plus CarPlay audio.
- Xtream, Stalker, M3U URLs and M3U files; Live TV, Movies and Series; search with voice.
- XMLTV guide with On now, guide search, channel guides and catch-up.
- libVLC player: raw MPEG-TS, HLS, MKV, MP4; audio description first; remembered tracks; subtitle files spoken; Chromecast; full screen; plays with the screen locked.
- Live playback starts in half a second and builds a 25-second cushion; dropped streams reconnect.
- Recordings, scheduled recordings and downloads, saved in the Files app.
- Settings export and import, including files from the Android app.
- 14 languages.
