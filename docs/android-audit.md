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
