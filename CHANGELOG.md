# Changelog

## 0.6.6

- Channels start in a couple of seconds again. The new playback engine was waiting until a full 25 seconds of the channel had arrived before showing the first picture — that is what its buffer setting means at join time — so every channel change took about 20 seconds. Live channels now join the fast way, starting on the first picture the source sends, the same quick start the app has always used on its other players. Stream probing at open is capped too, so a slow source cannot stretch the wait either.

## 0.6.5

- Live transport-stream channels (the kind Dispatcharr and Xtream live channels use) now play through a new playback engine, AetherEngine, instead of VLC. The new engine holds one long-lived connection and keeps your saved Buffer seconds as a cushion on the live edge that refills after a stutter, where VLC's fixed network cache read a bursty channel as starved and kept rebuffering no matter how large the buffer was set — channels like KCPQ should now ride out the short gaps at their source. If a channel fails on the new engine before its first picture, the app falls back to VLC for that channel automatically. Subtitles are still shown and spoken, audio track choice still applies, and everything else is unchanged: Apple's player still takes the streams it can play, and VLC still takes files and the remaining formats.

## 0.6.4

Everything in 0.6.3, plus:

- Channels start sooner: while you browse the channel list, the app warms a connection to the stream server in the background, so picking a channel no longer waits on a name lookup and a secure-connection handshake before the first picture can arrive. Nothing about the stream itself changes — the request that does the warming goes to the server's front door only, opens no channel, and the buffer settings are exactly as they were. The win is biggest for channels Apple's player handles; VLC channels gain the name lookup, because VLC keeps its own connection machinery.


## 0.6.3

- Dispatcharr is now recognised behind an Xtream login too, not only from its M3U playlist, so 0.6.2’s whole-buffer start applies to Xtream logins. Refresh sources once to pick it up straight away; otherwise it applies at the next automatic refresh, within 12 hours.
- When an Xtream server redirects http to https on the same address, live channels now connect over https directly instead of being redirected on every tune and reconnect.
- Fixed a channel that was playing being restarted after 25 seconds and given up after 30 (“Stream lost”). The player sometimes missed the moment playback started; it now checks the player’s state every second.

0.6.2 was not released: its build failed the same playback test this fixes.

## 0.6.2

- Dispatcharr channels now start with your whole saved buffer, as Android does after its first rebuffer. They used to start with half a second, and the player cannot add to its buffer once a channel is open, so every short pause at the source was heard as buffering. Starting takes longer: about the buffer setting in seconds, after the server is ready. Lower Buffer seconds in Settings for a faster start with less protection.
- A channel that takes long to start is no longer restarted or given up while its buffer fills: the 25 and 30 second limits now count from the end of the fill.

## 0.6.1

0.6.0 was not released: its build failed the playback tests.

- Settings, Copy playback log copies what the player saw since the app opened: each buffering spell and how long it lasted, what arrived from the server and what the player did with it every 10 seconds, reconnects and why, and when playback stopped. Paste it into a problem report. Times are in UTC. Stream addresses and logins are never included. Not on Apple TV.

## 0.5.0

- Live channels reconnect in place when the provider drops the connection. libVLC 4 ignored the old reconnect option, so a dropped MPEG-TS stream used to stop and reopen from scratch.
- HLS played through VLC now follows the buffer setting. It starts at least 15 seconds behind live, on segments the server already holds, so it starts fast and does not run dry. Apple playback of live HLS keeps its distance from live after a stall instead of drifting behind.
- New playback engine: SwiftVLC replaces the VLCKit 4 alpha. Same libVLC 4, with fixes for damaged transport streams and HLS crashes. The engine starts when the app opens, so the first channel connects sooner, and switching channels no longer waits on a polling loop.
- Closed captions, teletext and other text subtitles from the stream show under the video and are spoken, unless Speak subtitles is off. Picture subtitles stay in the image.
- Needs iOS 18, tvOS 18 or visionOS 2.
- A playlist's Cookie header is no longer sent: libVLC 4 has no cookie API.

## 0.4.10

- Fix constant live-stream reconnects: VLCKit 4 reports buffering from 0 to 1, but the app waited for 100. A healthy stream therefore stayed marked as buffering and the watchdog repeatedly reopened it. Buffering completion now clears that state correctly.
- Each reconnect gets fresh startup grace plus its configured cache time. Initial cache filling no longer counts as a prolonged stall, and Apple playback timeouts also allow the configured buffer to fill. Switching from Apple playback to VLC cancels any pending retry and gives the new backend its own startup deadline.
- Playback health now checks decoded audio and video and output counters before falling back to the playback clock, matching the Windows app. Missing or never-advancing clocks cannot declare a stream frozen. Video disabled in the background is excluded, and old progress samples are cleared on reopen, resume and return to the app. Repeated Play commands do not start a false no-media deadline.
- Extensionless Xtream live URLs with a numeric channel ID now use VLC directly for MPEG-TS, avoiding an unnecessary Apple-player attempt. Genuine reconnects log their cause and backend without logging provider URLs or credentials.

## 0.4.9

- Audit of connecting, the single connection, buffering, skipping back and reconnecting. Pausing or closing while a channel was still connecting could be announced as “One IPTV stream at a time” and could leave the provider connection claimed until the player screen closed; it now says nothing and hands the connection back at once.
- Buffering is announced while a channel connects, as on Android, instead of leaving “Connecting…” up silently until the first frame or “Stream lost”.
- A film or catch-up programme that stalls or errors now resumes where it stopped: the position is taken when the stall is detected, not after the reconnect wait, by which time an errored player could already report the start and skip the film back to the beginning. A Dispatcharr archive stream again earns the extra second per stall, as on the desktop; only its live channels keep the saved buffer.
- Once playback has failed, the playback-health checks stop, so a later “Stream lost” no longer overwrites the real reason (a busy provider or a timed-out teardown). While casting or converting for a receiver, the receiver owns playback and the phone no longer gives up on the stream or reopens it.
- CarPlay announces “Connecting…” and reconnects a dropped channel inside the same retry budget as the player screen, announcing “Reconnecting…” and then “Stream lost” when the budget is spent, instead of ending silently. The reconnect budget itself also starts again correctly after two quiet minutes even when its first attempt landed on clock zero.

## 0.4.8

- Buffering now follows the desktop app's rules end to end. A live channel reopened after a stall waits with the whole saved buffer before sound returns, instead of starting again on the half-second quick start every time — the changelog promised that full-cushion resume in 0.4.6, and the live player now actually does it. The buffer grows by a second only when a restart actually happens, not on every short dip.
- A stalled channel is reopened the desktop's way: buffering for 10 seconds, a frozen picture, or four stalls inside a minute reopen it with a bigger buffer. A stream that sends nothing restarts after 25 seconds, and one that has not played at all 30 seconds after it was chosen is announced as Stream lost instead of spinning silently.
- Films and catch-up get the same recovery: an error or a stall reopens them inside the same retry budget and resumes where they stopped, instead of failing at once. They also open with the full saved buffer, where they used to start on a flat 2 seconds.

## 0.4.7

- Channels from a Dispatcharr restreamer keep the buffer you saved. It restreams from its own server-side buffer, so a stalled channel no longer grows the client buffer by a second and no longer waits for a bigger cushion before sound returns. Same rule as the desktop app.

## 0.4.6

- A live channel no longer plays 5% slow while it fills its buffer. Playback stays at normal speed from the first second, and the buffer grows only from what the server hands over ahead of real time. The half-second quick start, the full-cushion resume after a stall, the one-second growth per stall, and the saved buffer in Settings are unchanged. Same rule as the desktop app.

## 0.4.5

- Stopping a stream could be reported as finished while VLC was still stopping, so the next channel, recording or conversion could start over the tail of the previous one. Playback teardown now waits until the stopped state has held briefly before anything else may use the connection.

## 0.4.4

- Playback, CarPlay, casting, recordings and downloads now share one IPTV media connection. Starting a conflicting operation leaves the current stream running and announces that it must be stopped first.
- Channel changes and playback handoffs wait for the previous reader to stop before opening another. Recordings and downloads also wait for their HTTP session to close before reconnecting or releasing the connection.
- Pausing or resuming while video conversion prepares no longer restarts the provider reader. Opening an external player first stops the app's own stream; playback in other apps remains outside this app's control.
- Playlist, guide and account requests remain separate from the media connection limit.

## 0.4.3

- Siri can play channels it previously could not find. The channel entity offered to Siri used the provider's raw label as its name, so decorated entries such as "UK: Sky | Mix HD" were far harder to match than clean ones, and every unnamed entry (whose label is its credential-bearing URL) was presented to Siri as plain "Channel".
- The entity now carries the spoken name as its title, with the provider label and channel number as alternate names, and unnamed entries fall back to their number or group so each stays distinguishable.
- A spoken channel that matches a name exactly now wins outright instead of competing with its look-alikes. A request for Sky Sports F1 no longer shares a short candidate list with Sky Sports 1 to 30.
- Both system paths use that resolution: the playback schema Siri AI calls and the Find Channels and Tune channel actions in Shortcuts.

## 0.4.2

- Siri AI can play a channel now. Saying "watch Sky Mix in Accessible IPTV" answered that the app does not support playing content directly through Siri, because Apple requires an action schema for that, and the app had none. It now adopts the audio domain's playback schemas: a live radio station entity for channels and the Play audio intent, both iOS 27 or later, with iOS 17 to 26 unchanged.
- Channel names, groups and numbers resolve through the same matching as everywhere else, so provider punctuation, quality labels and channel numbers still work.
- Shuffle, repeat and a queue position are accepted and ignored: a live channel plays or does not, and there is one stream at a time.
- The build now uses the Xcode 27 runner image, which is what ships the iOS 27 SDK these schemas need.

## 0.4.1

- Siri and Apple Intelligence now receive a written description of every channel, guide and search action, and of their channel and search parameters, alongside the spoken phrases. These descriptions are the signals the system matches a request against.
- More ways to ask with the app name: Watch, Play, Tune to, Put on and Start a channel, plus Watch live TV, and additional phrasings for what is on, guide search and opening a channel guide.
- Settings has a Siri and Shortcuts row that opens this app's page in Shortcuts, with the phrase guidance beside it. Apple requires App Shortcut phrases to include the app name; a shortcut of your own is the way to use a phrase without one.
- Audit result recorded in `research_notes/Siri channel playback/ios27-routing.md`: the conversational route Siri AI uses for everyday phrasing needs an action schema, and the audio schemas for live playback are iOS 27 APIs that need Xcode 27, which the build runner does not provide yet. Until then, the app-named phrases are the supported path and were verified in the 0.4.0 build's App Intents metadata and per-language NLU assets.

## 0.4.0

- Spotlight can find live channels by name or provider number on iPhone and iPad. Choosing a result opens the app and starts the channel. The full loaded live catalogue is indexed in batches, with spoken indexing status, retry after interruptions and removal of unavailable results after source changes. Stream URLs, logins and raw channel keys stay out of the index.
- On iOS 18 or later, channel search results are associated with indexed App Entities for Siri and Apple Intelligence discovery. iOS 17 retains ordinary Spotlight results. The system still determines recognition and availability; bare Siri commands continue to require personally named shortcuts.
- Shortcuts adds native Find Channels filters for name, group and number, sorting and result limits. Tune channel returns the selected channel for later actions. Saved multi-channel inputs preserve their requested order, and channel entities can be converted to their public names as text.
- Channel search now matches partial spoken names across provider punctuation, including Sky Mix, Sky | Mix and SkyMix. Discovery refreshes after every live catalogue load, including when the app opens on Movies or Series. Concurrent Siri loads share their work.
- Help, indexing status and the Open channel action are translated into all fourteen app languages. Physical Siri recognition and Spotlight ranking still require device testing.

## 0.3.4

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
