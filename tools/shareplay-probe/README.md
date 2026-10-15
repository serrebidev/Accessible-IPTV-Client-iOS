# Single-source SharePlay feasibility probe

This is an experiment, separate from the released app. It does not implement a working Apple Journal relay or change SharePlay in v0.2.0.

The user clarified the limit on 2026-10-15: one provider playback session on the host, with zero provider requests or logins on guests and no user-operated server. This includes live TV, HLS, movies and catch-up.

One playback session can include HLS playlist and media-segment requests ([RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html)) and movie range requests. The matrix logs these separately from the single VLC producer. It does not prove how a real provider counts an account's sessions.

The matrix reports local playback separately from production readiness. `requestedFeatureReady` remains false. A green workflow establishes only the local probe checks, not Apple-only delivery of the requested feature.

## Questions tested here

- Can the exact VLCKit already used by the app ingest TS, HLS, MP4, MKV and a catch-up-style URL and remux encoded streams into streaming Matroska?
- Can the producer remain independent of three local VLC consumers, with every provider request originating from that producer?
- Does a dedicated HTTP output bind to loopback and require authentication?
- Do both audio and video decode after copying the output, without leaking a synthetic provider URL marker?
- How long until output arrives, and does a file input respect real-time pacing?
- What happens when the producer seeks within an MP4?

The matrix uses generated H.264/AAC media, a local fake provider and an in-memory byte copy capped at 64 MiB. The `IPTVHostProbe/1` User-Agent is test instrumentation, not an authentication design. HTTP range and HLS requests are logged separately from the number of producer playback sessions. Consumers must sustain audio/video decoding throughout observation and advance native playback time. Producer errors, early EOF, and output reconnects after the first byte fail the test. Seeking must produce later native time and demux progress; this does not establish frame-accurate seeking or playback synchronization.

The TS fixture is finite, HLS uses a VOD playlist, and the fake provider ignores catch-up query parameters. These exercise input containers and URL handling; they do not establish indefinite live streaming, adaptive HLS changes, or real provider catch-up semantics.

## Result (run 38806942463, 2026-10-15)

All six cases passed: TS, HLS, MP4, MKV, catch-up URL and MP4 seek. Three local consumers decoded audio and video from one producer in every case. Guests made zero provider requests.

First remuxed bytes arrived in 0.5 to 1.3 seconds. Provider HTTP requests from the single producer session: TS 1, catch-up 1, MKV 3, MP4 4, MP4 seek 4, HLS 12 (playlist plus segments). At most 2 were open at once.

Earlier failures were probe bugs, not VLC: `HTTPServer.server_bind` called `socket.getfqdn()`, which stalled 35 seconds on the runner.

## Running on macOS

```sh
swift build --package-path tools/shareplay-probe -c release
FRAMEWORK=$(find tools/shareplay-probe/.build/artifacts -type d -path '*macos*/VLCKit.framework' | head -1)
export DYLD_FRAMEWORK_PATH="$(dirname "$FRAMEWORK")"
python3 tools/shareplay-probe/run_probe.py --binary tools/shareplay-probe/.build/release/RelayProbe --output probe-results
```

Requires Xcode, Python 3.9 or newer, and ffmpeg with libx264. The workflow uploads results and per-process logs, including failure evidence. No real IPTV account or production media is used. The fixed HTTP test password is only for the temporary loopback fixture.

## Native delivery remains a separate gate

Apple describes GroupSessionJournal as encrypted file/data transfer, with a 100 MB attachment limit. It gives no sustained streaming rate or deadline. Its add operation can complete before upload finishes. Journal attachments have no documented sender identity or playback ordering, and removing an attachment affects everyone.

A future prototype therefore needs authenticated host manifests through GroupSessionMessenger, attachment IDs bound to hashes and ordered stream generations, bounded buffers, acknowledgements after receivers copy bytes, and explicit handling for slow receivers, late joiners, host loss and seeks. Guests must never fall back to opening the provider URL. Background audio must be tested with a separate producer and local consumer; deselecting source video tracks may remove video from the remux as well as the local picture.

This local matrix cannot establish sustained delivery through Apple, device background execution, codec compatibility beyond the fixture, HLS adaptive track changes, late-join decoding or end-to-end SharePlay synchronization. Those need a real-device FaceTime transport probe before a production feature or stable release can claim the requested behavior.

References: [Apple data sharing](https://developer.apple.com/documentation/groupactivities/synchronizing-data-during-a-shareplay-activity), [Share files with SharePlay](https://developer.apple.com/videos/play/wwdc2023/10241/), [pinned VLCKit package](https://github.com/videolan/vlckit/blob/4.0.0-a22/Package.swift), [VLC HTTP output](https://github.com/videolan/vlc/blob/c9628afc4/modules/access_output/http.c), [VLC Matroska output example](https://mailman.videolan.org/pipermail/vlc-commits/2019-January/053655.html).
