import { mockRTCPeerConnection, unmockRTCPeerConnection } from '../__test__/mockRTCPeerConnection';
import { mockRTCRtpReceiver, unmockRTCRtpReceiver } from '../__test__/mockRTCRtpReceiver';
import { Config } from '../Config/Config';
import { PeerConnectionController } from './PeerConnectionController';

const bitrateParams = 'x-google-start-bitrate=10000;x-google-max-bitrate=100000';

const buildVideoSdp = (codecLines: string[]) =>
    [
        'v=0',
        'o=- 1 2 IN IP4 127.0.0.1',
        's=-',
        't=0 0',
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100',
        'c=IN IP4 0.0.0.0',
        'a=mid:0',
        'a=recvonly',
        ...codecLines,
        ''
    ].join('\r\n');

const h265Lines = [
    'a=rtpmap:96 H265/90000',
    'a=rtcp-fb:96 nack',
    'a=fmtp:96 level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST',
    'a=rtpmap:97 rtx/90000',
    'a=fmtp:97 apt=96'
];
const h264Lines = [
    'a=rtpmap:98 H264/90000',
    'a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
];
const otherCodecLines = [
    'a=rtpmap:99 AV1/90000',
    'a=fmtp:99 level-idx=5;profile=0;tier=0',
    'a=rtpmap:100 VP9/90000',
    'a=fmtp:100 profile-id=0'
];

describe('PeerConnectionController', () => {
    let controller: PeerConnectionController;

    beforeEach(() => {
        mockRTCPeerConnection();
        mockRTCRtpReceiver();
        controller = new PeerConnectionController({}, new Config(), '');
    });

    afterEach(() => {
        unmockRTCRtpReceiver();
        unmockRTCPeerConnection();
        jest.resetAllMocks();
    });

    it('should parse H.265 from the remote sdp', () => {
        const sdp = buildVideoSdp([...h265Lines, ...h264Lines]);

        const codecs = controller.parseAvailableCodecs({ type: 'offer', sdp });

        expect(codecs).toEqual([
            'H265 level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST',
            'H264 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
        ]);
    });

    it('should add bitrate params to H.264 and H.265 fmtp lines only', () => {
        const sdp = buildVideoSdp([...h265Lines, ...h264Lines, ...otherCodecLines]);

        const lines = controller.mungeSDP(sdp, false).split('\r\n');

        expect(lines).toContain(
            `a=fmtp:96 level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST;${bitrateParams}`
        );
        expect(lines).toContain(
            `a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f;${bitrateParams}`
        );
        expect(lines).toContain('a=fmtp:97 apt=96');
        expect(lines).toContain('a=fmtp:99 level-idx=5;profile=0;tier=0');
        expect(lines).toContain('a=fmtp:100 profile-id=0');
    });

    it('should add an fmtp line with bitrate params for H.265 if there is none', () => {
        const sdp = buildVideoSdp(['a=rtpmap:96 H265/90000', 'a=rtcp-fb:96 nack', ...h264Lines]);

        const lines = controller.mungeSDP(sdp, false).split('\r\n');

        expect(lines.indexOf(`a=fmtp:96 ${bitrateParams}`)).toEqual(
            lines.indexOf('a=rtpmap:96 H265/90000') + 1
        );
    });
});
