# Changelog

## 0.1.5

- Fixes from an audit of 0.1.4. A search for a name with an accent (é, ü, ñ, and non-Latin scripts alike) came back empty when the feed wrote that letter with the accent as a separate mark instead of one letter, which some providers do. Both spellings are matched again.
- Names of the same search rank are ordered by how many characters they have, as before, so a short accented name no longer sorts below a longer plain one.
- After refreshing playlists, a channel no longer keeps the guide entry it had when the list first loaded (or the lack of one) for the rest of the session. Xtream and Stalker entries keep their number when a provider renames a channel or fixes its guide id, so the match is worked out again from the new list.
- Deleting the last playlist no longer leaves the list from before on screen, where the rows could still be played from a playlist that is gone.

## 0.1.4

- The category list on a phone opens from one button and is now a lazy list: only the rows on screen are built. It used to be a menu that built an entry for every category on every redraw of the screen, so a provider with hundreds of categories was slow to open and slowed everything else down with it. The button shows the category you are in and how many entries it has.

## 0.1.3

- No more long freeze when the app opens, comes back into focus, or switches between Live TV, Movies and Series. Two jobs ran on the main thread, and both grew with the size of the list: reading the guide's channel index before the first frame, and working out the entry count beside every group. The index is now read while the list loads, and the counts are one pass, off the main thread.

## 0.1.2

- Much less CPU while typing in the search field: a keystroke over a 50,000 channel list went from 0.16 s to 0.01 s (measured on a desktop, release build; a phone is slower). The names are prepared once when a list loads, and matching them no longer goes through the text search that was costing the time.
- A fresh launch no longer hashes every channel on the main thread to check whether the guide is still current: it is done once, in the background, while the list loads, and only when the guide could need it.
- A guide that matched no channel is not fetched again on every load, and a failed import waits an hour before the next automatic try.

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
