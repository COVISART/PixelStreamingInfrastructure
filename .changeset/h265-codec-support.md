---
'@epicgames-ps/lib-pixelstreamingfrontend-ue5.7': minor
'@epicgames-ps/pixelstreaming-sfu': minor
---

Add H.265/HEVC support for streamers that offer it.

- The default preferred codec is now H.265 when the browser can decode it (Chrome 136+ with a
  hardware decoder, Safari 18+). Otherwise it is H.264, then the first codec the browser reports.
  You can still choose a codec in the settings panel or with `?PreferredCodec=`.
- The SDP answer now adds the `x-google-start-bitrate` and `x-google-max-bitrate` hints to H.265,
  as it already did for H.264, so H.265 streams don't start at a low bitrate.
- If `PreferredCodec` names a codec the browser doesn't support (for example H265 on Firefox), the
  frontend logs a warning and uses the default codec. If `setCodecPreferences` fails, the frontend
  logs a warning instead of leaving an unhandled rejection.
- The SFU router now accepts H.265. Set `enableH265: false` in `SFU/config.js` to turn this off. The
  SFU forwards one codec to every viewer, so when the streamer negotiates H.265, every viewer must be
  able to decode it.
