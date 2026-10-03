// Copyright Epic Games, Inc. All Rights Reserved.

import { Logger } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';

export class BrowserUtils {
    static getSupportedVideoCodecs(): Array<string> {
        const browserSupportedCodecs: Array<string> = [];
        // Try get the info needed from the RTCRtpReceiver. This is only available on chrome
        if (!RTCRtpReceiver.getCapabilities) {
            Logger.Warning(
                'RTCRtpReceiver.getCapabilities API is not available in your browser, defaulting to guess that we support H.264.'
            );
            browserSupportedCodecs.push(
                'H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
            );
            return browserSupportedCodecs;
        }

        const matcher = /(VP\d|H26\d|AV1).*/;
        const capabilities = RTCRtpReceiver.getCapabilities('video');
        if (!capabilities) {
            browserSupportedCodecs.push(
                'H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
            );
            return browserSupportedCodecs;
        }
        capabilities.codecs.forEach((codec) => {
            const str = codec.mimeType.split('/')[1] + ' ' + (codec.sdpFmtpLine || '');
            const match = matcher.exec(str);
            if (match !== null) {
                browserSupportedCodecs.push(str);
            }
        });
        return browserSupportedCodecs;
    }

    /**
     * Build the codec list to hand to `RTCRtpTransceiver.setCodecPreferences`, with the preferred codec first.
     * The returned entries are the browser's own capability objects, as `setCodecPreferences` rejects any codec
     * that is not one of them.
     * @param preferredCodec The codec in the form produced by `getSupportedVideoCodecs`, i.e. "<Name> <fmtp>".
     * @param capabilities The video codecs reported by `RTCRtpReceiver.getCapabilities('video')`.
     * @returns The reordered codecs, or null if the browser does not support the preferred codec.
     */
    static buildCodecPreferences(
        preferredCodec: string,
        capabilities: Array<RTCRtpCodec>
    ): Array<RTCRtpCodec> | null {
        const separatorIndex = preferredCodec.indexOf(' ');
        const name = (
            separatorIndex === -1 ? preferredCodec : preferredCodec.slice(0, separatorIndex)
        ).trim();
        const fmtp = separatorIndex === -1 ? '' : preferredCodec.slice(separatorIndex + 1).trim();
        if (name === '') {
            return null;
        }

        const mimeType = `video/${name}`.toLowerCase();
        const sameCodec = capabilities.filter((codec) => codec.mimeType.toLowerCase() === mimeType);
        if (sameCodec.length === 0) {
            return null;
        }

        // Prefer the entry with the exact parameters. Without one, any profile of the preferred codec beats other codecs.
        const exactMatch = sameCodec.find((codec) => (codec.sdpFmtpLine ?? '') === fmtp);
        const preferred = exactMatch ? [exactMatch] : sameCodec;
        return [...preferred, ...capabilities.filter((codec) => !preferred.includes(codec))];
    }
}
