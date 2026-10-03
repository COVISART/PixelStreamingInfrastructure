import { Logger } from '@epicgames-ps/lib-pixelstreamingcommon-ue5.8';
import { Config, OptionParameters } from '../Config/Config';
import {
    chromeVideoCodecs,
    mockRTCRtpReceiverWithCodecs,
    unmockRTCRtpReceiver
} from '../__test__/mockRTCRtpReceiver';
import {
    mockRTCPeerConnection,
    MockRTCPeerConnectionSpyFunctions,
    unmockRTCPeerConnection
} from '../__test__/mockRTCPeerConnection';
import { PeerConnectionController } from './PeerConnectionController';

const h264Fmtp = 'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f';
const h265Fmtp = 'level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST';
const bitrateHints = ';x-google-start-bitrate=10000;x-google-max-bitrate=100000';

const sdpOf = (...lines: string[]) => lines.join('\r\n') + '\r\n';

const h265Offer = sdpOf(
    'v=0',
    'o=- 1 2 IN IP4 127.0.0.1',
    's=-',
    't=0 0',
    'm=video 9 UDP/TLS/RTP/SAVPF 96 97',
    'c=IN IP4 0.0.0.0',
    'a=mid:0',
    'a=rtpmap:96 H265/90000',
    `a=fmtp:96 ${h265Fmtp}`,
    'a=rtpmap:97 rtx/90000',
    'a=fmtp:97 apt=96'
);

const withoutH265 = chromeVideoCodecs.filter((codec) => codec.mimeType !== 'video/H265');

const createVideoTransceiver = () => ({
    receiver: { track: { kind: 'video' } },
    setCodecPreferences: jest.fn()
});

describe('PeerConnectionController', () => {
    let rtcPeerConnectionSpyFunctions: MockRTCPeerConnectionSpyFunctions;
    let warningSpy: jest.SpyInstance;

    // The preferred codec option is built from the browser capabilities when the Config is created,
    // so the codecs the browser reports have to be mocked first.
    const createController = (preferredCodec: string, browserCodecs = chromeVideoCodecs) => {
        mockRTCRtpReceiverWithCodecs(browserCodecs);
        const config = new Config();
        const controller = new PeerConnectionController({}, config, preferredCodec);
        return { config, controller };
    };

    beforeEach(() => {
        [rtcPeerConnectionSpyFunctions] = mockRTCPeerConnection();
        warningSpy = jest.spyOn(Logger, 'Warning').mockImplementation(() => undefined);
    });

    afterEach(() => {
        unmockRTCRtpReceiver();
        unmockRTCPeerConnection();
        jest.restoreAllMocks();
    });

    describe('mungeSDP', () => {
        it('should add the bitrate hints to H265 fmtp lines', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);

            const munged = controller.mungeSDP(h265Offer, false);

            expect(munged).toContain(`a=fmtp:96 ${h265Fmtp}${bitrateHints}\r\n`);
        });

        it('should leave the rtx fmtp line of an H265 stream alone', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);

            const munged = controller.mungeSDP(h265Offer, false);

            expect(munged).toContain('a=fmtp:97 apt=96\r\n');
        });

        it('should only touch the fmtp line of the H265 payload type', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            const sdp = sdpOf(
                'm=video 9 UDP/TLS/RTP/SAVPF 9 96',
                'a=rtpmap:9 H265/90000',
                `a=fmtp:9 ${h265Fmtp}`,
                'a=rtpmap:96 VP9/90000',
                'a=fmtp:96 profile-id=0'
            );

            const munged = controller.mungeSDP(sdp, false);

            expect(munged).toContain(`a=fmtp:9 ${h265Fmtp}${bitrateHints}\r\n`);
            expect(munged).toContain('a=fmtp:96 profile-id=0\r\n');
        });

        it('should only add the bitrate hints once to an H265 fmtp line that has level-asymmetry-allowed', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            // mediasoup adds level-asymmetry-allowed to the H265 parameters it offers
            const fmtp = `level-asymmetry-allowed=1;${h265Fmtp}`;
            const sdp = sdpOf('m=video 9 UDP/TLS/RTP/SAVPF 96', 'a=rtpmap:96 H265/90000', `a=fmtp:96 ${fmtp}`);

            const munged = controller.mungeSDP(sdp, false);

            expect(munged).toContain(`a=fmtp:96 ${fmtp}${bitrateHints}\r\n`);
            expect(munged.match(/x-google-start-bitrate/g)).toHaveLength(1);
        });

        it('should still add the bitrate hints to H264 fmtp lines', () => {
            const { controller } = createController(`H264 ${h264Fmtp}`);
            const sdp = sdpOf('m=video 9 UDP/TLS/RTP/SAVPF 96', 'a=rtpmap:96 H264/90000', `a=fmtp:96 ${h264Fmtp}`);

            const munged = controller.mungeSDP(sdp, false);

            expect(munged).toContain(`a=fmtp:96 ${h264Fmtp}${bitrateHints}\r\n`);
        });

        it('should not add the bitrate hints to other codecs', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            const sdp = sdpOf(
                'm=video 9 UDP/TLS/RTP/SAVPF 96 98',
                'a=rtpmap:96 VP9/90000',
                'a=fmtp:96 profile-id=0',
                'a=rtpmap:98 AV1/90000',
                'a=fmtp:98 level-idx=5;profile=0;tier=0'
            );

            const munged = controller.mungeSDP(sdp, false);

            expect(munged).not.toContain('x-google');
        });

        it('should leave an H265 stream without an fmtp line unchanged', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            const sdp = sdpOf('m=video 9 UDP/TLS/RTP/SAVPF 96', 'a=rtpmap:96 H265/90000');

            expect(controller.mungeSDP(sdp, false)).not.toContain('x-google');
        });
    });

    describe('parseAvailableCodecs', () => {
        it('should list the H265 codec of the remote sdp with its parameters', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);

            expect(controller.parseAvailableCodecs({ type: 'offer', sdp: h265Offer })).toEqual([
                `H265 ${h265Fmtp}`
            ]);
        });
    });

    describe('fuzzyIntersectUEAndBrowserCodecs', () => {
        it('should keep H265 when the browser supports it', () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);

            expect(controller.fuzzyIntersectUEAndBrowserCodecs({ type: 'offer', sdp: h265Offer })).toEqual([
                `H265 ${h265Fmtp}`
            ]);
        });

        it('should return nothing when the browser does not support H265', () => {
            const { controller } = createController(`H264 ${h264Fmtp}`, withoutH265);

            expect(controller.fuzzyIntersectUEAndBrowserCodecs({ type: 'offer', sdp: h265Offer })).toEqual([]);
        });
    });

    describe('setPreferredCodecOptions', () => {
        it('should set the preferred codec options to the codecs both sides support', () => {
            const { config, controller } = createController(`H265 ${h265Fmtp}`);

            controller.setPreferredCodecOptions({ type: 'offer', sdp: h265Offer });

            expect(config.getSettingOption(OptionParameters.PreferredCodec).options).toEqual([
                `H265 ${h265Fmtp}`
            ]);
            expect(warningSpy).not.toHaveBeenCalled();
        });

        it('should warn when the browser supports none of the codecs the streamer offered', () => {
            const { config, controller } = createController(`H264 ${h264Fmtp}`, withoutH265);

            controller.setPreferredCodecOptions({ type: 'offer', sdp: h265Offer });

            expect(config.getSettingOption(OptionParameters.PreferredCodec).options).toEqual([]);
            expect(warningSpy).toHaveBeenCalledTimes(1);
            expect(warningSpy).toHaveBeenCalledWith(expect.stringContaining(`H265 ${h265Fmtp}`));
        });

        it('should not warn when the browser cannot report its codecs', () => {
            const { controller } = createController(`H264 ${h264Fmtp}`);
            // Browsers without RTCRtpReceiver.getCapabilities (e.g. Firefox) can't be matched against the offer
            global.RTCRtpReceiver = {} as typeof global.RTCRtpReceiver;
            warningSpy.mockClear();

            controller.setPreferredCodecOptions({ type: 'offer', sdp: h265Offer });

            expect(warningSpy).not.toHaveBeenCalled();
        });
    });

    describe('setupTransceiversAsync', () => {
        it('should prefer the codec using the browser capabilities', async () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            const transceiver = createVideoTransceiver();
            controller.peerConnection.getTransceivers = () => [transceiver as unknown as RTCRtpTransceiver];

            await controller.setupTransceiversAsync(false, false);

            expect(transceiver.setCodecPreferences).toHaveBeenCalledTimes(1);
            const preferences = transceiver.setCodecPreferences.mock.calls[0][0] as RTCRtpCodec[];
            expect(preferences[0]).toBe(chromeVideoCodecs.find((codec) => codec.mimeType === 'video/H265'));
            expect(preferences).toHaveLength(chromeVideoCodecs.length);
        });

        it('should skip setting the codec preferences when the browser does not support the preferred codec', async () => {
            const { controller } = createController(`H265 ${h265Fmtp}`, withoutH265);
            const transceiver = createVideoTransceiver();
            controller.peerConnection.getTransceivers = () => [transceiver as unknown as RTCRtpTransceiver];

            await controller.setupTransceiversAsync(false, false);

            expect(transceiver.setCodecPreferences).not.toHaveBeenCalled();
            expect(warningSpy).toHaveBeenCalledWith(expect.stringContaining('H265'));
            // The rest of the setup carries on
            expect(rtcPeerConnectionSpyFunctions.addTransceiverSpy).toHaveBeenCalledWith('audio', {
                direction: 'recvonly'
            });
        });

        it('should carry on when the browser rejects the codec preferences', async () => {
            const { controller } = createController(`H265 ${h265Fmtp}`);
            const transceiver = createVideoTransceiver();
            transceiver.setCodecPreferences.mockImplementation(() => {
                throw new Error('InvalidModificationError');
            });
            controller.peerConnection.getTransceivers = () => [transceiver as unknown as RTCRtpTransceiver];

            await expect(controller.setupTransceiversAsync(false, false)).resolves.toBeUndefined();

            expect(warningSpy).toHaveBeenCalledWith(expect.stringContaining('InvalidModificationError'));
            expect(rtcPeerConnectionSpyFunctions.addTransceiverSpy).toHaveBeenCalledWith('audio', {
                direction: 'recvonly'
            });
        });

        it('should not touch the codec preferences when there is no preferred codec', async () => {
            const { controller } = createController('');
            const transceiver = createVideoTransceiver();
            controller.peerConnection.getTransceivers = () => [transceiver as unknown as RTCRtpTransceiver];

            await controller.setupTransceiversAsync(false, false);

            expect(transceiver.setCodecPreferences).not.toHaveBeenCalled();
        });
    });
});
