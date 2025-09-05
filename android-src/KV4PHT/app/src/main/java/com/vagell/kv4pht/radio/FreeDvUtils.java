package com.vagell.kv4pht.radio;

import java.nio.FloatBuffer;
import java.nio.ShortBuffer;

import com.ustadmobile.codec2.Codec2;

public final class FreeDvUtils {

    private FreeDvUtils() {
    }

    // ---- tiny short ring ----
    static final class ShortRing {

        private final short[] buf;
        private int r = 0, w = 0, size = 0;

        ShortRing(int cap) {
            buf = new short[cap];
        }

        int available() {
            return size;
        }

        void write(short[] src, int len) {
            int cap = buf.length;
            for (int i = 0; i < len && size < cap; i++) {
                buf[w] = src[i];
                w = (w + 1) % cap;
                size++;
            }
        }

        int read(short[] dst, int len) {
            int n = Math.min(len, size);
            for (int i = 0; i < n; i++) {
                dst[i] = buf[r];
                r = (r + 1) % buf.length;
            }
            size -= n;
            return n;
        }
    }

    // ===================== TX =====================

    /**
     * FreeDV TX: speech@8k float[len==speechFrameSize] -> FreeDV -> Opus packet.
     */
    public static final class Tx implements AutoCloseable {

        private final long h;
        private final int speechInPerFrame;
        private final int modemOutMax;
        private final int opusFrameSamples;
        private final OpusUtils.OpusEncoderWrapper opus;

        // Internals
        private final short[] speechPcm;
        private final short[] modemPcm;
        private final ShortRing modemRb;
        private final short[] oneOpusShort;
        private final float[] opusFloat;
        private final byte[] pktBuf;
        private int lastPktLen = 0;

        public Tx(int freedvMode, int opusFrameSamples, OpusUtils.OpusEncoderWrapper opusEncoder, int mtuBytes) {
            this.h = Codec2.freedvCreate(freedvMode, false, 0f, 1);
            if (h == 0) {
                throw new IllegalStateException("freedvCreate(TX) failed");
            }

            this.speechInPerFrame = Codec2.freedvGetNSpeechSamples(h);
            this.modemOutMax = Codec2.freedvGetMaxModemSamples(h);
            this.opusFrameSamples = opusFrameSamples;
            this.opus = opusEncoder;

            this.speechPcm = new short[speechInPerFrame];
            this.modemPcm = new short[modemOutMax];
            this.modemRb = new ShortRing(opusFrameSamples * 8);
            this.oneOpusShort = new short[opusFrameSamples];
            this.opusFloat = new float[opusFrameSamples];
            this.pktBuf = new byte[mtuBytes];
        }

        /**
         * Feed one speech frame (len must equal speechFrameSize). Returns Opus packet length (0 if none ready).
         */
        public int pushSpeechFrame(float[] speech8k, int len) {
            if (len != speechInPerFrame) {
                throw new IllegalArgumentException("len=" + len + " != speechFrameSize=" + speechInPerFrame);
            }

            // float -> pcm16
            for (int i = 0; i < speechInPerFrame; i++) {
                float x = speech8k[i];
                if (x > 1f) {
                    x = 1f;
                } else if (x < -1f) {
                    x = -1f;
                }
                speechPcm[i] = (short) Math.round(x * 32767f);
            }

            int nModem = (int) Codec2.freedvTx(h, modemPcm, speechPcm);
            if (nModem > 0) {
                modemRb.write(modemPcm, nModem);
            }

            if (modemRb.available() >= opusFrameSamples) {
                modemRb.read(oneOpusShort, opusFrameSamples);
                for (int i = 0; i < opusFrameSamples; i++) {
                    opusFloat[i] = oneOpusShort[i] / 32768f;
                }
                lastPktLen = opus.encode(opusFloat, pktBuf);
                return Math.max(0, lastPktLen);
            }
            lastPktLen = 0;
            return 0;
        }

        public byte[] packetBuffer() {
            return pktBuf;
        }

        public int lastPacketLength() {
            return lastPktLen;
        }

        public int speechFrameSize() {
            return speechInPerFrame;
        }

        public int opusFrameSize() {
            return opusFrameSamples;
        }

        @Override
        public void close() {
            Codec2.freedvDestroy(h);
        }
    }

    // ===================== RX =====================

    /**
     * FreeDV RX: Opus(8k) packet -> FreeDV -> speech@8k FLOAT (internal buffer).
     */
    public static final class Rx implements AutoCloseable {

        private final long freeDv;
        private final short[] speechRxBuffer;
        ShortBuffer speechSamples;
        FloatBuffer pcmFloatBuffer;
        private final OpusUtils.OpusDecoderWrapper opus;
        private final short[] modemTmp;

        public Rx(int freedvMode, float squelchSnr, int opusFrameSamples, OpusUtils.OpusDecoderWrapper opusDecoder) {
            freeDv = Codec2.freedvCreate(freedvMode, true, squelchSnr, 0);   // unset for speech
            if (freeDv == 0) {
                throw new IllegalStateException("freedvCreate(RX) failed");
            }
            speechRxBuffer = new short[Codec2.freedvGetMaxSpeechSamples(freeDv)];
            speechSamples = ShortBuffer.allocate(1024 * 10);
            pcmFloatBuffer = FloatBuffer.allocate(1024 * 10);
            modemTmp   = new short[opusFrameSamples];
            opus = opusDecoder;
        }

        /**
         * Push one Opus packet (8k). Returns #float samples written into speechFloatBuffer(). Buffer contents are valid
         * until the next call.
         */
        public int pushOpusPacket(byte[] opusData, int len) {
            pcmFloatBuffer.clear();
            int got = opus.decode(opusData, len, modemTmp);
            if (got > 0) {
                speechSamples.put(modemTmp, 0, got);
            }
            int nin = Codec2.freedvNin(freeDv);
            while (speechSamples.position() >= nin) {
                short[] samplesSpeech = new short[nin];
                speechSamples.flip();
                speechSamples.get(samplesSpeech);
                speechSamples.compact();
                int cntRead = (int)Codec2.freedvRx(freeDv, speechRxBuffer, samplesSpeech);
                if (cntRead > 0) {
                    for (int i = 0; i < cntRead; i++) {
                        float x = speechRxBuffer[i] / 32768f;
                        pcmFloatBuffer.put(x);
                    }
                }
                nin = Codec2.freedvNin(freeDv);
            }
            return pcmFloatBuffer.position();
        }

        @Override
        public void close() {
            Codec2.freedvDestroy(freeDv);
        }

        public float[] speechFloatBuffer() {
            pcmFloatBuffer.flip();
            return pcmFloatBuffer.array();
        }
    }
}
