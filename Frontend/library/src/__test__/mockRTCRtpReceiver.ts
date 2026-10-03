export const mockRTCRtpReceiverImpl = {
    prototype: jest.fn(),
    getCapabilities: () => ({
        codecs: [
            {
                clockRate: 60,
                mimeType: "testMimeType",
                sdpFmtpLine: "AV1"
            }
        ] as RTCRtpCodec[],
        headerExtensions: [] as RTCRtpHeaderExtensionCapability[]
    })
} as any as typeof global.RTCRtpReceiver;

/**
 * The video codecs a Chromium browser with HEVC decoding support reports, including the non-media
 * entries (rtx/red/ulpfec) that must not be offered as selectable codecs.
 */
export const chromeVideoCodecs: RTCRtpCodec[] = [
    { clockRate: 90000, mimeType: 'video/VP8' },
    { clockRate: 90000, mimeType: 'video/rtx' },
    { clockRate: 90000, mimeType: 'video/VP9', sdpFmtpLine: 'profile-id=0' },
    { clockRate: 90000, mimeType: 'video/VP9', sdpFmtpLine: 'profile-id=2' },
    { clockRate: 90000, mimeType: 'video/AV1', sdpFmtpLine: 'level-idx=5;profile=0;tier=0' },
    {
        clockRate: 90000,
        mimeType: 'video/H264',
        sdpFmtpLine: 'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f'
    },
    {
        clockRate: 90000,
        mimeType: 'video/H264',
        sdpFmtpLine: 'level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f'
    },
    { clockRate: 90000, mimeType: 'video/H265', sdpFmtpLine: 'level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST' },
    { clockRate: 90000, mimeType: 'video/red' },
    { clockRate: 90000, mimeType: 'video/ulpfec' }
];

const originalRTCRtpReceiver = global.RTCRtpReceiver;
export const mockRTCRtpReceiver = () => {
    global.RTCRtpReceiver = mockRTCRtpReceiverImpl;
}

/**
 * Mock RTCRtpReceiver reporting the given video codecs, for tests that need realistic codec capabilities.
 * Restore the original with unmockRTCRtpReceiver.
 */
export const mockRTCRtpReceiverWithCodecs = (codecs: RTCRtpCodec[]) => {
    global.RTCRtpReceiver = {
        prototype: jest.fn(),
        getCapabilities: () => ({
            codecs,
            headerExtensions: [] as RTCRtpHeaderExtensionCapability[]
        })
    } as any as typeof global.RTCRtpReceiver;
}

export const unmockRTCRtpReceiver = () => {
    global.RTCRtpReceiver = originalRTCRtpReceiver;
}
