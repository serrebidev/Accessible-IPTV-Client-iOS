# Changelog

## 0.3.3

- Siri channel tuning now recognises the app-qualified Play, Tune to and Watch phrases. Provider names such as UK: Sky | Mix HD expose the spoken alias Sky Mix, and channel numbers are alternate spoken names.
- Every favourite and recently watched channel is offered to Siri, with vocabulary refreshed after playback and favourite changes. The former twenty-channel limit could hide recent channels behind favourites. Default suggestions stay small for large playlists.
- Say Watch TV in Accessible IPTV, Play TV in Accessible IPTV or Tune to a channel in Accessible IPTV to have Siri ask for a channel and search the full live playlist. Matching ignores provider decoration while keeping +1 channels separate.
- Help in all fourteen languages explains the commands and how to create a personal Shortcut named Play Sky Mix for a command without the app name. Automatic App Shortcut phrases still require the app name. Physical-device Siri recognition remains to be checked.

## 0.3.2

- Guide audit fixes. What's On Now, guide search and one channel's guide now load in windows of 2,000 programmes with a More row, instead of building every row at once, and filtering no longer re-runs on every redraw.
- One channel's guide now has the filter field, and programmes are grouped under day headings so VoiceOver heading navigation jumps a day at a time. Past programmes speak their date, a finished load announces its programme count, and the screen refreshes itself when a guide import completes behind it. An empty guide offers Import guide in place.
- The Guide section now has a Channel guide picker: pick a channel by name instead of hunting through Browse categories.
- Searching the guide says when two characters are needed and when only the first 500 results are shown; typing another character now narrows the last answer instead of scanning the whole guide again. Guide match and now/next caches evict a slice at their caps instead of emptying, so scrolling a huge category no longer re-runs queries row by row.
- Tapping a programme that has not started yet now shows its details instead of playing the channel; recording it stays in its row actions.

## 0.3.1

- Playback destination is now one combined list: This device, AirPlay device, and every Cast device labelled as a Cast device. The separate Prepare AirPlay video button is gone. Picking an AirPlay device starts on-device conversion automatically when the stream needs it; compatible streams play natively as before.
- Converted video keeps the source resolution instead of being capped at 720p. It is still converted at 30 frames per second, and the receiver decides what it can decode, so an older receiver may still refuse a high-resolution stream.

## 0.3.0

- AVPlayer now handles compatible HLS, MP4 and other native media. Unsupported formats and playback failures fall back to VLCKit. Raw provider `.ts` URLs remain unchanged.
- On iPhone and iPad, Prepare AirPlay video converts other IPTV video on the device to H.264/AAC HLS, then exposes Apple’s AirPlay destination picker. Playback destination uses the same conversion for Chromecast. No separate server or new media dependency is required.
- Conversion targets up to 720p at 30 frames per second. Choose audio and subtitles before casting and keep the app open on the receiver’s Wi-Fi. Protected streams, unavailable encoders and device performance can prevent conversion; local playback remains available. Physical receiver, thermal and locked-phone behavior still require device testing.
- Provider handoffs wait for VLC’s asynchronous stop, cancel old reconnect work and allow single-session providers to release the old connection. HLS output fixes invalid rendition references and live playlist tags, caches complete manifests and removes expired segment files.
- Playback, conversion failures and AirPlay connection changes have visible and spoken status. Controls and help cover all 14 app languages. Sources are available in Settings, with Add sources shown when Browse is empty.
- Adds an iOS simulator integration gate using MPEG-2/MP2 input and a decoded AVPlayer video frame, plus immediate-stop and natural-end restart regressions. iOS, tvOS and visionOS builds retain the existing signing and SharePlay entitlements.

## 0.2.0

- SharePlay uses FaceTime and Apple's native custom-player coordinator for shared channel selection, play and pause, and seekable movie, episode and catch-up timing. Each participant resolves content through their own playlist and login; stream URLs and credentials are never shared. Leave and End for everyone are separate controls. Live streams share controls, with timing limited by provider buffering.
- Native iPhone and iPad navigation: Browse, Guide, Recordings and Settings tabs, system search, and playlist controls in the navigation bar. Categories open first; All channels is an explicit choice.
- Minimize playback into a persistent video miniplayer while browsing. Expanding it keeps the same player and stream. Pause and Stop playback are separate controls.
- Playback survives closing the expanded player and uses the iOS background audio session, lock-screen and headset controls. Calls interrupt playback, automatic resume respects an explicit pause, and disconnecting headphones pauses playback.
- Siri and Shortcuts on iPhone can tune channels by name or number, read the current and next programme, search the imported guide, open a channel guide, and pause, resume or stop playback. Favourites and recent channels provide bounded suggestions; duplicate channel numbers remain separate choices.
- Focused channel rows and the player expose onscreen App Entity context on iOS 18.2 or later. Apple Intelligence experiences depend on device, language and system support; the actions also work without Apple Intelligence. Guide answers use imported XMLTV data.
- New controls, shortcut phrases and help are translated into all 14 app languages.

## 0.1.9

- A category opens in a fraction of a second again. The measurement added in 0.1.8 found why: the channel list built a row for every entry in the category rather than only the rows on screen, and one category of 93,816 channels spent 5.8 seconds building them before anything appeared. The list is now built from 2,000 rows at a time; where there are more, the end of the list carries a More button that says how many are left and doubles what is shown, so the whole category stays reachable.
- The measuring line from 0.1.8 stays in for now. It says nothing unless a change takes over a second.

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
