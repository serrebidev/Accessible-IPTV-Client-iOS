# Changelog

## 0.1.8

- This build measures the slow category switch. When a category change or a list load takes more than a second, the status line now says what it cost: the time before the list was shown, how many rows the list built, and how many times the screen redrew. Temporary, and it goes away once the cost is known.
- The guide lookup that a channel row makes is remembered for half a minute, so a redraw or a scroll over a list of live channels no longer runs the same query for every row again.

## 0.1.7

- Choosing a category, changing section, or typing the first letter of a search now builds the channel list fresh for what was asked for, instead of asking the list to work out the difference from the category before it. That pass costs what the list costs, which is 5 to 8 seconds on an account with tens of thousands of channels.
- The same category with new content, such as a favourite or a recording starting, still updates in place rather than rebuilding.
- Channel rows no longer animate in and out when a whole list is replaced.

## 0.1.6

- Fixes from a second audit, of the player, the recorder, CarPlay and voice search.
- Recording the same channel twice inside one minute wrote both recordings to one file, and the second emptied the first: the file name only goes down to the minute. A second recording now gets its own name.
- Starting or stopping Cast no longer says "stream ended" (or "reconnecting") after saying what it is doing, and no longer opens the stream a second time.
- Playback started from CarPlay keeps its lock screen and steering wheel play and pause: closing the player screen used to wipe the Now Playing card and the remote controls that CarPlay had taken over, while the sound kept playing.
- The Voice button no longer crashes the app when it is pressed again while the first press is still asking for microphone and speech permission, or when the microphone then fails to start.

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
