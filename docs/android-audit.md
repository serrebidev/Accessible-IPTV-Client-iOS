# Audit: Accessible IPTV Client for Android 0.2.11

Read in full before the iOS port: every Kotlin source, layout, the 14 string files, the help files and
the tests. Findings, most important first. "iOS" says what the port does about it.

## Bugs

1. **Credentials in stream paths are form-encoded.** `Xtream.liveChannels`, `movies` and `parseEpisodes`
   build `/live/<user>/<pass>/<id>.ts` with `URLEncoder.encode`, which writes a space as `+`. In a URL
   path `+` is a literal plus, so a username or password with a space (or `+`, `&`, `/`) reaches the
   server wrong. `credentialsFromUrl` decodes path segments the same wrong way. Fix: percent-encode path
   segments (`Uri.encode`), decode them without the `+` rule. iOS: fixed, with a test.
2. **Stop can take up to 60 s on a stalled stream.** `Recorder.copy` relies on `Thread.interrupt()`, but a
   blocking socket read is not interruptible; a stream that stops sending holds Stop until the 60 s read
   timeout. Fix: close the connection's input stream from `ACTION_STOP_ONE` (keep it in the job map), or
   a shorter read timeout for recordings. iOS: cancelling the task cancels the URLSession request at once.
3. **ACTION_STOP calls `stopSelf()` while threads are still finishing.** The `finally` that clears
   `IS_PENDING` and posts "Saved" runs after the service is gone; if the process is reclaimed in between,
   the file stays pending (hidden in Movies). Fix: stop when the last job leaves, as `ACTION_STOP_ONE` does.
4. **Guide imports queue instead of failing fast.** `Epg.import` is `synchronized`, so a manual
   Refresh guide during the automatic one waits and then downloads the whole guide again. iOS: a second
   import is refused with a message.
5. **The recording notification names only the first recording.** `startForeground(1, …)` is called with
   each new job's name but the one notification is shared; with two recordings it shows whichever started
   last and never updates when one ends.

## Localization gaps (shown in English in all 14 languages)

- Account info labels: Status, Expires, Never, Trial, Yes, No, Connections in use, "N days left",
  "expired", Created; Stalker's Plan, Expires, Balance, Name.
- Episode names: "Season %s, Episode %s".
- Programme times: `Format.programme` hard-codes "to" ("News, 18:00 to 18:30"), which every row, Details
  and the player's "Now:" line speak.
- Errors: "Playlist removed", "Not a settings file", "Server answered N", "Portal handshake failed",
  "Checksum mismatch", "Guide ended early".
- Group fallbacks "Ungrouped" and "Stalker" (provider data, lower priority).

iOS: all of these except the network error texts and group fallbacks are translated in 14 languages.

## Smaller issues

- `AudioTracks.tokens` splits on `[\W_]+` with Java's ASCII-only `\W`, so "hörfilm" becomes "h" + "rfilm"
  and "descripción" becomes "descripci" + "n". Matching stays symmetric, so it mostly still works, but the
  whole-word rule for short keywords is weakened on accented names. Fix: `(?U)` flag. iOS: Unicode-aware.
- `Updater.download` skips the SHA-256 check when GitHub publishes no digest (PackageInstaller's
  same-signature rule still protects the install).
- `android:allowBackup="true"` puts playlist logins and passwords in device backups; Export settings also
  writes them in plain JSON (same as the desktop, by design; worth a line in Help).
- `App.channel(key)` scans every loaded list, movies included (100k+), on the main thread from the player
  and the guide screens.
- `Recorder.schedule` ids are `currentTimeMillis % Int.MAX_VALUE`; two schedules in the same millisecond
  collide (theoretical).
- KDoc for `Epg.import` sits above `endOf`, so the import function shows no documentation.

## Accessibility

No blocking problems. Rows are one stop with custom actions, headings are real headings, form errors
move TalkBack to the field, status changes use a polite live region, and the player has no auto-hiding
controls. Notes:

- The channel row's "★" glyph is visual only; speech says "favourite" (good). Keep it that way.
- The main screen status line announces every load result, including the routine channel count after
  each section switch; consider announcing counts only when the user asked (Refresh).
- Subtitle speech uses a polite live region per cue; long cues can queue behind status announcements.

# iOS CPU and memory audit (0.1.1)

Reported: CPU out of control after adding an Xtream login. Cause: the guide import.

Measured with `Core/Tests/IPTVCoreTests/PerfTests.swift` (release build, desktop CPU; a phone is
roughly 3 to 5 times slower). Synthetic 45 MB guide, 2,000 channels, 1 in 100 matched.

| Path | 0.1.0 | 0.1.1 |
| --- | --- | --- |
| XMLTV reader | 10 MB/s | 121 MB/s |
| Xtream JSON list reader | 30 MB/s | 58 MB/s |

Fixes:

1. XML reader went byte by byte and built a String for every text run, whitespace included.
   Now it finds `<` with memchr, keeps text as bytes until asked, and `skipElement()` jumps over
   a programme of an unmatched channel without tokenizing it (most of a national guide).
2. JSON strings are copied in runs up to the next quote or backslash.
3. `Channel.key` (the SwiftUI row id) was built by string interpolation on every access; every
   list diff did it 50,000 times. Now stored.
4. The main screen re-ran the whole channel List on every status-line change. The rows are now
   an Equatable view compared by a version number.
5. Each row ran `Xmltv.nameKey` and prepared a fresh SQLite statement for now/next. Guide ids are
   cached per channel and reader statements are prepared once.
6. Gzip allocated a 256 KB buffer per chunk; one buffer per stream now.
7. Player: the channel was looked up (a scan of every list, movies included) on each programme
   change; now once. The subtitle-cue timer (150 ms) runs only with a subtitle file loaded, the
   track timer stops once a track is chosen, the pace timer runs for live only.
8. Recorder wrote and published its schedule every 15 s; now only when it changes.

Memory, unchanged and acceptable:

- Guides download to a temp file and stream from disk; SQLite page cache is 4 MB; the reader
  holds one 256 KB chunk. A guide import stays a few MB regardless of guide size.
- Lists live in memory like on Android: about 500 bytes per entry, so 250,000 movies is about
  125 MB. ponytail: move lists to SQLite if that ever becomes a problem.
- The list cache is written and read as one JSON blob, briefly doubling a section's memory
  while it saves or loads.
- libVLC holds the live cushion: 25 s at 8 Mbit/s is about 25 MB.

# iOS CPU audit (0.1.2)

Reported: high CPU on a fresh launch, and while typing in the search field.

Measured with `Core/Tests/IPTVCoreTests/PerfTests.swift` (`swift test -c release`, desktop CPU; a
phone is roughly 3 to 5 times slower), 50,000 channels with playlist-shaped names.

| One keystroke over 50k channels | 0.1.1 | 0.1.2 |
| --- | --- | --- |
| Search | 0.159 s | 0.009 s |
| Launch, guide staleness hash | 0.21 s on the main thread | 0.21 s on the loading thread, only when a recent guide can need it |

Fixes:

1. Search matched each name with Foundation's `String.range(of:)` (ICU). A bench of the parts, in
   release: lowercasing 50,000 names 0.010 s, `range(of:)` over them 0.061 s, a UTF-8 byte scan of
   them 0.002 s. The match was the cost, so `Lists.rank` now scans the name's bytes for the query,
   keeping ICU for the character-boundary edge case and for strings with no contiguous storage.
   The test asserts both paths give identical results, non-ASCII names included.
2. Names are no longer trimmed and lowercased on every keystroke: the Library keeps the search form
   of each name from load time. On Apple's Foundation that was the smaller half (0.016 s of a
   0.098 s keystroke). It was measured on Windows first, where `trimmingCharacters` is far slower,
   and that overstated it.
3. `guideStale()` hashed every live channel's match key (`Xmltv.nameKey`: 0.218 s per 50,000) on the
   main thread at every launch. The hash is now computed once per load, on the loading thread, and
   only when the guide is recent enough to be compared; after an import the value is kept, so the
   next check does not redo it.

Left alone, deliberately:

- A search still matches every loaded channel and sorts the hits, exactly like the desktop and
  Android versions (neither caps the result count), and it already ran off the main thread. A
  250,000 movie section costs about 5x the table above per keystroke. ponytail: a search index if
  that ever proves too slow on a phone.
- The groups list and picker are rebuilt when the screen redraws. It is a few hundred entries, small
  next to the search, so it was left alone.

# iOS responsiveness audit (0.1.3)

Reported: the app takes a long time to open, shows nothing for a long time when opened or brought
back into focus, and the same when switching lists.

Two jobs ran on the main thread. Both are proportional to the number of channels, so on a big
Xtream account they are seconds:

1. `Library.init` read the whole guide channel index (`Epg.loadIndex`: one row per channel the guide
   matched) before the app's first frame, because the app builds its Library while building its
   first window. It is now read where the rest of the list work happens: on the thread doing the
   section load (and after an import, as before).
2. `MainView.refreshGroupCounts` walked the section three times on the main thread - once to count
   each group, once to count the favourites, once for the group names in playlist order - and it ran
   after every load, every favourites change and every section switch. A 250,000 movie list is the
   freeze that was reported. It is now one pass, `Library.groupSummary`, run off the main thread.

Not measured on a device; this is a removal of main-thread work, not a benchmark. Both jobs still
cost what they cost, on the thread that is allowed to be busy.

Left alone, deliberately:

- Reading a section's cache is one JSON decode of up to 50 MB, off the main thread. It is why the
  list itself can take a moment to appear on a big account; the screen stays responsive and says
  Loading. ponytail: a binary cache if that ever measures badly on a phone.
- The phone's category picker built an entry for every category as a menu, on every redraw. Fixed in
  0.1.4, below.
- `List` still works out the rows for the new list on every change, proportional to the list. That
  is SwiftUI's own work and there is nothing to remove without giving up the list.

# iOS category list (0.1.4)

Follow-up from the 0.1.3 audit. The phone showed the categories as a menu picker, so every redraw of
the screen - every keystroke in the search field, every status-line change - built an entry for every
category the provider has, which is hundreds on Xtream. Those entries were built merely to show the
screen, and the menu was built again every time it was opened.

It is now one button showing the current category and its entry count, opening the lazy `List` sheet
(`ChoiceSheet`) the app already uses for recently watched and external players. Only the rows in view
exist, and the entries are built when the sheet opens rather than on every redraw. iPad, Apple TV and
Vision Pro already used a `List` and are unchanged.

The sheet is still one swipe per category with VoiceOver. ponytail: a filter field in it, if finding
one of 500 categories by swiping is as bad as it sounds.

# iOS category switch (0.1.7)

Reported: choosing a category takes 5 to 8 seconds to show its channels.

The channel list was keyed by nothing but the version number, so choosing a category handed SwiftUI
the same `List` with a completely different array in it. SwiftUI then worked out the difference
between the category before and the one after - a pass proportional to the number of rows, and an
insert and a delete for each of them. Tens of thousands of channels is seconds, and this is the
cost the 0.1.3 audit named and left alone ("nothing to remove without giving up the list").

`ChannelRows` is now keyed (`MainView.listID`) by what it is showing: the section, the category, or
that a search is running. Choosing a category builds a fresh list, which only builds the rows in
view. The same category with new content - a favourite, a recorder state, a redraw - keeps its
identity and still updates in place, and a transaction with the animation off means nothing animates
thousands of rows when a whole list is replaced.

Not measured on a device. If a category is still slow, the next suspect is the work each row does
when it is built: `ChannelRows.row` runs one SQLite now/next query per row (with the guide id and
the statement cached). One `List` build asks for many rows - SwiftUI's own count, not the ten or so
on screen. The way to settle that is to count the rows a build asks for, and the fix that follows is
a row that fills its guide line in from its own task instead of during the build.

# iOS category switch, second pass (0.1.8)

0.1.7 keyed the channel list by what it is showing, so a category switch builds the rows instead of
working out the difference from the category before. Reported back: still the same 5 seconds. So the
difference was not the cost, and the list bookkeeping is not it either. What is left:

- How many rows SwiftUI asks for when a list changes. If it asks for a whole category, each row
  costs a guide query, a localization lookup and a few formatters, and tens of thousands of them
  is seconds.
- A redraw loop between the main screen and the list, each redraw rebuilding what the last one did.

This build measures instead of guessing again. When a category change or a load takes over a
second, the status line reports what it cost: the time before the list was shown, the rows the list
built (`SwitchTiming.row` in `ChannelRows.row`), and the redraws of the main screen
(`SwitchTiming.body`). Those numbers pick one of the two, and the fix follows: a row that fills its
guide line in from its own task for the first, or whatever the redraw count exposes for the second.
The measurement goes away once the cost is known.

Also in 0.1.8: `Epg.nowNext` remembers its answer for half a minute (`Epg.nowCache`, dropped by
`loadIndex` on an import). A row asks for the same channel again on every redraw and every scroll,
and that query was the only I/O a row did.

# iOS category switch, measured (0.1.9)

The measurement came back from the device:

    SLOW Canada: Entertainment: filter 46 ms, 93816 rows in 5836 ms, 10 redraws, 7662 ms total

So: the filter and the group counts are not the cost (46 ms for the whole section). The list built
93,816 rows for one category - about 62 microseconds each, and 5.8 seconds of frozen screen - while
Apple documents List rows as loading lazily and only about a dozen are on screen. Whatever defeats
that laziness here (the candidates are the value-matched focus modifiers on every row,
`.focused(_:equals:)` and `.accessibilityFocused(_:equals:)`, and the per-row `contextMenu`), the
effect is that the list builds every row of the category it is handed.

The fix bounds what it is handed: `MainView.window` gives the list 2,000 rows, and a "More" row at
the end of the list - a real row, one VoiceOver stop - says how many are left and doubles the
window, so a 93,816-channel category is fully reachable in a few presses. Rows are still the same
rows, the heading still shows the whole count, "Go to channel number" and Details still search the
whole list, and a new category starts at its head again (`shownFor`).

At 62 microseconds a row the 2,000-row window costs about 0.12 seconds, which is why the measuring
line from 0.1.8 should now stay silent.

Left alone, deliberately: why SwiftUI builds every row, which would make the window unnecessary. It
is not worth removing the focus or menu behaviour of a row to find out, since the window bounds the
cost either way. If rows ever get cheaper, the window can be raised or made scroll-driven.
