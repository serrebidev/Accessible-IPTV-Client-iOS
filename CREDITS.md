# Credits

This is the iOS port of [Accessible IPTV Client for Android](https://github.com/serrebidev/Accessible-IPTV-Client-Android), the companion to [Accessible IPTV Client](https://github.com/serrebidev/Accessible-IPTV-Client) for Windows and Linux. Same player, rebuilt for VoiceOver on iPhone, iPad, Apple TV, and Vision Pro.

Third-party projects it uses:

- AVPlayer for compatible streams.
- libVLC (via VLCKit) for raw MPEG-TS, MKV, and other IPTV formats AVPlayer cannot play.
- VLC, Infuse, nPlayer, and Outplayer can take over playback from the app.
- The VLC playback coordinator follows Apple's custom-player playback coordinator documentation and the independent VLCKitEngine implementation in [marvinvr/dusk-player](https://github.com/marvinvr/dusk-player/blob/main/Dusk/Sources/Playback/VLCKitEngine.swift).

Xtream Codes, Stalker Portal, and M3U/M3U Plus are upstream protocols and formats, not code from this project.

Questions and bug reports are welcome in the [SerrebiProjects Telegram group](https://t.me/SerrebiProjects). More serrebi projects: [projects.serrebiradio.com](https://projects.serrebiradio.com).
