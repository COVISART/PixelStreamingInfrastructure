---
"@epicgames-ps/pixelstreaming-sfu": minor
---

Add opt-in H.265/HEVC support to the SFU with a new `enableH265` option in `config.js` (default `false`), which registers `video/H265` on the mediasoup router so an H.265 streamer can be forwarded to players. mediasoup removed H.265 support in 3.16.6, so `mediasoup` is now pinned to exactly `3.15.5` (previously `^3.15.5`, which a fresh install, including the SFU Docker image's `npm update`, could resolve to a version without H.265). If `enableH265` is set and the installed mediasoup doesn't support H.265, the SFU logs an error at startup and carries on without it rather than failing to create the router.
