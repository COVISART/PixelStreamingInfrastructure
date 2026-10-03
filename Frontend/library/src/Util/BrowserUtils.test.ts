import {
    chromeVideoCodecs,
    mockRTCRtpReceiverWithCodecs,
    unmockRTCRtpReceiver
} from '../__test__/mockRTCRtpReceiver';
import { BrowserUtils } from './BrowserUtils';

const h264Fmtp = 'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f';
const h265Fmtp = 'level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST';

describe('BrowserUtils', () => {
    afterEach(() => {
        unmockRTCRtpReceiver();
    });

    describe('getSupportedVideoCodecs', () => {
        it('should list H265 alongside the other video codecs', () => {
            mockRTCRtpReceiverWithCodecs(chromeVideoCodecs);

            const codecs = BrowserUtils.getSupportedVideoCodecs();

            expect(codecs).toContain(`H265 ${h265Fmtp}`);
            expect(codecs).toContain(`H264 ${h264Fmtp}`);
            expect(codecs.some((codec) => codec.startsWith('VP8'))).toBe(true);
            expect(codecs.some((codec) => codec.startsWith('AV1'))).toBe(true);
        });

        it('should not list rtx, red or ulpfec as selectable codecs', () => {
            mockRTCRtpReceiverWithCodecs(chromeVideoCodecs);

            const codecs = BrowserUtils.getSupportedVideoCodecs();

            expect(codecs.some((codec) => /^(rtx|red|ulpfec)/.test(codec))).toBe(false);
        });

        it('should not list H265 when the browser does not support it', () => {
            mockRTCRtpReceiverWithCodecs(chromeVideoCodecs.filter((codec) => codec.mimeType !== 'video/H265'));

            const codecs = BrowserUtils.getSupportedVideoCodecs();

            expect(codecs.some((codec) => codec.startsWith('H265'))).toBe(false);
        });
    });

    describe('buildCodecPreferences', () => {
        it('should put the exact preferred codec first and keep every other codec', () => {
            const preferences = BrowserUtils.buildCodecPreferences(`H265 ${h265Fmtp}`, chromeVideoCodecs);

            expect(preferences).not.toBeNull();
            expect(preferences?.[0].mimeType).toBe('video/H265');
            expect(preferences?.[0].sdpFmtpLine).toBe(h265Fmtp);
            expect(preferences).toHaveLength(chromeVideoCodecs.length);
            expect(preferences?.slice(1)).toEqual(
                chromeVideoCodecs.filter((codec) => codec.mimeType !== 'video/H265')
            );
        });

        it('should return the browser capability objects rather than copies', () => {
            const preferences = BrowserUtils.buildCodecPreferences(`H265 ${h265Fmtp}`, chromeVideoCodecs);

            for (const codec of preferences ?? []) {
                expect(chromeVideoCodecs).toContain(codec);
            }
        });

        it('should select only the exact profile when several profiles of the codec exist', () => {
            const preferences = BrowserUtils.buildCodecPreferences(`H264 ${h264Fmtp}`, chromeVideoCodecs);

            expect(preferences?.[0].sdpFmtpLine).toBe(h264Fmtp);
            // The other H264 profile is kept, just no longer first
            expect(preferences?.[1].mimeType).toBe('video/VP8');
            expect(preferences).toHaveLength(chromeVideoCodecs.length);
        });

        it('should put every profile of the codec first when only the codec name is given', () => {
            const preferences = BrowserUtils.buildCodecPreferences('H264', chromeVideoCodecs);

            expect(preferences?.[0].mimeType).toBe('video/H264');
            expect(preferences?.[1].mimeType).toBe('video/H264');
            expect(preferences).toHaveLength(chromeVideoCodecs.length);
        });

        it('should fall back to the codec when the parameters are not supported', () => {
            const preferences = BrowserUtils.buildCodecPreferences(
                'H265 level-id=120;profile-id=2;tier-flag=0;tx-mode=SRST',
                chromeVideoCodecs
            );

            expect(preferences?.[0].mimeType).toBe('video/H265');
            expect(preferences?.[0].sdpFmtpLine).toBe(h265Fmtp);
        });

        it('should match the codec name case insensitively', () => {
            const preferences = BrowserUtils.buildCodecPreferences(`h265 ${h265Fmtp}`, chromeVideoCodecs);

            expect(preferences?.[0].mimeType).toBe('video/H265');
        });

        it('should match a codec without parameters', () => {
            const preferences = BrowserUtils.buildCodecPreferences('VP8 ', chromeVideoCodecs);

            expect(preferences?.[0].mimeType).toBe('video/VP8');
            expect(preferences).toHaveLength(chromeVideoCodecs.length);
        });

        it('should return null when the browser does not support the preferred codec', () => {
            const withoutH265 = chromeVideoCodecs.filter((codec) => codec.mimeType !== 'video/H265');

            expect(BrowserUtils.buildCodecPreferences(`H265 ${h265Fmtp}`, withoutH265)).toBeNull();
        });

        it('should return null for an empty or unusable preferred codec', () => {
            expect(BrowserUtils.buildCodecPreferences('', chromeVideoCodecs)).toBeNull();
            expect(BrowserUtils.buildCodecPreferences(' level-id=93', chromeVideoCodecs)).toBeNull();
            expect(BrowserUtils.buildCodecPreferences('Only available on Chrome', chromeVideoCodecs)).toBeNull();
        });
    });
});
